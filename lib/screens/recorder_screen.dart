import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';
import '../services/background_encode_service.dart';
import '../services/project_repository.dart';
import '../services/audio_merge_service.dart';
import '../services/audio_visibility_service.dart';
import '../services/recording_notification_service.dart';
import '../services/wav_recovery_service.dart';

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({
    required this.repository,
    required this.preferences,
    required this.onSaved,
    this.existingProject,
    this.resumeSessionId,
    this.createProject = false,
    super.key,
  });

  final ProjectRepository repository;
  final AppPreferences preferences;
  final VoidCallback onSaved;
  final RavenProject? existingProject;
  final String? resumeSessionId;
  final bool createProject;

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _clock = Stopwatch();
  final RecordingNotificationService _recordingNotification =
      RecordingNotificationService();
  final List<double> _levels = List<double>.filled(42, 0.08);
  Timer? _ticker;
  StreamSubscription<Amplitude>? _amplitudeSubscription;

  bool _started = false;
  bool _paused = false;
  bool _saving = false;
  bool _busy = false;
  String _elapsed = '00:00';
  String? _projectId;
  String? _sessionId;
  String? _outputPath;
  String? _recordingTitle;
  String? _captureFormat;
  int _captureSampleRate = 44100;
  int _lastNotificationSecond = -1;
  Object? _lastError;

  bool get _hasUnsavedRecording => _started;
  bool get _isResume => widget.resumeSessionId != null;

  @override
  void initState() {
    super.initState();
    RecordingNotificationService.setActionHandler((action) async {
      if (action == 'pause') {
        await _togglePause();
      } else if (action == 'stop') {
        await _saveRecording();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startRecording());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _amplitudeSubscription?.cancel();
    _clock.stop();

    if (_started && !_saving) {
      _forceCleanupRecording();
    } else {
      RecordingNotificationService.setActionHandler(null);
      try {
        _recorder.dispose();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _forceCleanupRecording() async {
    final repository = widget.repository;
    final projectId = _projectId;
    final sessionId = _sessionId;
    final sampleRate = _captureSampleRate;
    final isResume = _isResume;

    try {
      String? path;
      try {
        path = await _recorder.stop();
      } catch (_) {}
      try {
        await _recordingNotification.stop();
      } catch (_) {}

      if (path != null && projectId != null && sessionId != null) {
        if (isResume) {
          try {
            final f = File(path);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        } else {
          try {
            final duration = await WavRecoveryService().repairPcm16File(
              File(path),
              sampleRate: sampleRate,
            );
            final draft = repository.projectById(projectId);
            if (draft != null && duration != null) {
              final sessions = draft.sessions
                  .map((s) => s.id == sessionId
                      ? s.copyWith(
                          audioPath: path,
                          durationMs: duration,
                          recoverablePcm16: true,
                          sampleRate: sampleRate,
                        )
                      : s)
                  .toList();
              await repository.update(
                  draft.copyWith(sessions: sessions, isDraft: true));
            }
          } catch (_) {}
        }
      }
    } finally {
      try {
        _recorder.dispose();
      } catch (_) {}
      RecordingNotificationService.setActionHandler(null);
    }
  }

  Future<void> _startRecording() async {
    if (_busy || _started || !mounted) return;
    var notificationPermissionGranted = true;
    setState(() {
      _busy = true;
      _lastError = null;
    });
    try {
      final notificationsAllowed =
          await _recordingNotification.requestNotificationPermission();
      notificationPermissionGranted = notificationsAllowed;
      if (!notificationsAllowed) {
        throw StateError(
            'Allow notifications so the ongoing recording controls remain available in the background.');
      }
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        _showMessage(tr(
            widget.preferences,
            'Microphone permission is required.',
            'L’autorisation du microphone est nécessaire.'));
        if (mounted) Navigator.of(context).pop();
        return;
      }

      final existingProject = widget.existingProject;
      RavenAudioSession? targetSession;
      if (_isResume) {
        if (existingProject == null) {
          throw StateError('resumeSessionId requires existingProject');
        }
        if (existingProject.isAudioProtected) {
          throw StateError(
              'Decrypt this project before resuming its recording.');
        }
        try {
          targetSession = existingProject.sessions
              .firstWhere((s) => s.id == widget.resumeSessionId);
        } catch (_) {
          throw StateError(
              'The recording you are trying to resume no longer exists.');
        }
      }

      final captureTarget =
          _isResume ? 'wav' : widget.preferences.recordingFormat.toLowerCase();
      final (captureEncoder, captureExt) = _pickCaptureEncoder(captureTarget);
      final captureSampleRate = targetSession?.sampleRate ??
          existingProject?.currentSampleRate ??
          widget.preferences.sampleRate;

      final projectId = existingProject?.id ?? widget.repository.newId();
      final shouldCreateProject = existingProject != null
          ? !existingProject.isStandalone
          : widget.createProject;
      final newSessionId = const Uuid().v4();
      final createdAt = DateTime.now();
      final titleStamp =
          DateFormat('dd MMM yyyy, HH:mm', 'en').format(createdAt);
      final draftTitle = existingProject?.title ??
          '${tr(widget.preferences, 'Recording', 'Enregistrement')} — $titleStamp';
      final sessionNumber = (existingProject?.sessions.length ?? 0) + 1;

      final folderPreview = existingProject ??
          RavenProject(
            id: projectId,
            title: draftTitle,
            createdAt: createdAt,
            updatedAt: createdAt,
            sessions: const <RavenAudioSession>[],
            isStandalone: !shouldCreateProject,
            isDraft: true,
          );

      // Standalone recordings store their audio flat in recordingsDirectory —
      // no per-recording folder is ever created on disk.
      final Directory sessionDirectory;
      if (!shouldCreateProject) {
        sessionDirectory = widget.repository.recordingsDirectory;
        await sessionDirectory.create(recursive: true);
      } else {
        // Full project: create the named folder tree.
        Directory projectDirectory;
        try {
          projectDirectory =
              await widget.repository.ensureProjectFolder(folderPreview);
        } catch (_) {
          projectDirectory = Directory(
              '${widget.repository.projectsDirectory.path}/${widget.repository.projectFolderName(folderPreview)}');
          await projectDirectory.create(recursive: true);
        }
        sessionDirectory = Directory('${projectDirectory.path}/sessions');
        await sessionDirectory.create(recursive: true);
      }

      final safeTitle = draftTitle
          .trim()
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
          .replaceAll(RegExp(r'\s+'), '_');
      final fileTitle = safeTitle.isEmpty
          ? 'Recording'
          : safeTitle.length > 48
              ? safeTitle.substring(0, 48)
              : safeTitle;

      final fileName = _isResume
          ? 'resume-take-${const Uuid().v4()}.$captureExt'
          : '$fileTitle-session-$sessionNumber-$newSessionId.$captureExt';
      final filePath = '${sessionDirectory.path}/$fileName';

      _projectId = projectId;
      _sessionId = _isResume ? targetSession!.id : newSessionId;
      _outputPath = filePath;
      _recordingTitle = draftTitle;
      _captureFormat = captureExt;
      _captureSampleRate = captureSampleRate;

      if (!_isResume) {
        final newSession = RavenAudioSession(
          id: newSessionId,
          audioPath: filePath,
          createdAt: createdAt,
          durationMs: 0,
          format: captureExt,
          name: '$draftTitle · Session $sessionNumber',
          sampleRate: captureSampleRate,
          recoverablePcm16: captureExt == 'wav',
          bitRate: widget.preferences.bitRate, // BITRATE: set on creation
        );
        final draft = existingProject == null
            ? RavenProject(
                id: projectId,
                title: draftTitle,
                createdAt: createdAt,
                updatedAt: createdAt,
                sessions: <RavenAudioSession>[newSession],
                isStandalone: !shouldCreateProject,
                isDraft: true,
              )
            : existingProject.copyWith(
                updatedAt: createdAt,
                sessions: <RavenAudioSession>[
                  ...existingProject.sessions,
                  newSession,
                ],
                isDraft: true,
                clearMasterAudioPath: true,
              );
        if (existingProject == null) {
          await widget.repository.add(draft);
        } else {
          await widget.repository.update(draft);
        }
      }

      await _recorder.start(
        RecordConfig(
          encoder: captureEncoder,
          sampleRate: captureSampleRate,
          bitRate: widget.preferences.bitRate,
          numChannels: 1,
          autoGain: widget.preferences.voiceProcessing,
          echoCancel: widget.preferences.voiceProcessing,
          noiseSuppress: widget.preferences.voiceProcessing,
        ),
        path: filePath,
      );

      _started = true;
      _clock
        ..reset()
        ..start();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        final elapsedSecond = _clock.elapsed.inSeconds;
        if (elapsedSecond != _lastNotificationSecond) {
          _lastNotificationSecond = elapsedSecond;
          _updateRecordingNotification();
        }
        setState(() {
          _elapsed = _formatDuration(_clock.elapsed);
        });
      });
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 120))
          .listen((amplitude) {
        if (!mounted) return;
        final normalized = ((amplitude.current + 60.0) / 60.0).clamp(0.06, 1.0);
        setState(() {
          _levels.removeAt(0);
          _levels.add(normalized.toDouble());
        });
      }, onError: (Object error) {
        _lastError = error;
      });
      await _recordingNotification.start(
        title: _recordingTitle ??
            tr(widget.preferences, 'Recording', 'Enregistrement'),
        elapsedMs: 0,
        paused: false,
      );
      if (mounted) setState(() {});
    } catch (error) {
      _lastError = error;
      var preservedPartial = false;
      if (_started) {
        _clock.stop();
        _ticker?.cancel();
        try {
          final stoppedPath = await _recorder.stop();
          final path = stoppedPath ?? _outputPath;
          if (path != null && !_isResume) {
            final draft = _projectId == null
                ? null
                : widget.repository.projectById(_projectId!);
            final sessionId = _sessionId;
            if (draft != null && sessionId != null) {
              final duration = await WavRecoveryService().repairPcm16File(
                File(path),
                sampleRate: _captureSampleRate,
              );
              if (duration != null) {
                final sessions = draft.sessions
                    .map((session) => session.id == sessionId
                        ? session.copyWith(
                            audioPath: path,
                            durationMs: duration,
                            recoverablePcm16: true,
                            sampleRate: _captureSampleRate,
                          )
                        : session)
                    .toList();
                await widget.repository
                    .update(draft.copyWith(sessions: sessions, isDraft: true));
                preservedPartial = true;
              }
            }
          }
        } catch (recoveryError) {
          _lastError = recoveryError;
        }
      }
      try {
        await _recordingNotification.stop();
      } catch (_) {}
      _started = false;
      _paused = false;
      _showMessage(tr(
          widget.preferences,
          preservedPartial
              ? 'Recording stopped unexpectedly. The recoverable audio draft was kept in your library.'
              : !notificationPermissionGranted
                  ? 'Allow notifications so RAVEN can keep recording controls available in the background.'
                  : 'Could not start recording. Check microphone access and storage.',
          preservedPartial
              ? 'L’enregistrement s’est arrêté de façon inattendue. Le brouillon audio récupérable a été conservé dans votre bibliothèque.'
              : !notificationPermissionGranted
                  ? 'Autorisez les notifications pour que RAVEN garde les commandes d’enregistrement disponibles en arrière-plan.'
                  : 'Impossible de démarrer l’enregistrement. Vérifiez le microphone et le stockage.'));
      final id = _projectId;
      if (id != null && !preservedPartial) {
        try {
          if (_isResume) {
            final partial = _outputPath == null ? null : File(_outputPath!);
            if (partial != null && await partial.exists()) {
              await partial.delete();
            }
          } else if (widget.existingProject != null) {
            final original = widget.existingProject!;
            await widget.repository.update(original);
            final partial = _outputPath == null ? null : File(_outputPath!);
            if (partial != null && await partial.exists()) {
              await partial.delete();
            }
          } else {
            final draft = widget.repository.projectById(id);
            if (draft != null) {
              await widget.repository.deleteForever(draft);
            }
          }
        } catch (_) {}
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  (AudioEncoder, String) _pickCaptureEncoder(String targetFormat) {
    return switch (targetFormat) {
      'wav' => (AudioEncoder.wav, 'wav'),
      // Native FLAC capture is unsupported by MediaRecorder on most Android devices
      // and causes immediate crash/exception. We safely capture lossless PCM WAV
      // and transcode to FLAC losslessly in the background.
      'flac' => (AudioEncoder.wav, 'wav'),
      'mp3' => (AudioEncoder.wav, 'wav'),
      'm4a' || 'aac' => (AudioEncoder.aacLc, 'm4a'),
      _ => (AudioEncoder.aacLc, 'm4a'),
    };
  }

  Future<void> _updateRecordingNotification() async {
    try {
      await _recordingNotification.update(
        title: _recordingTitle ??
            tr(widget.preferences, 'Recording', 'Enregistrement'),
        elapsedMs: _clock.elapsedMilliseconds,
        paused: _paused,
      );
    } catch (error) {
      _lastError = error;
    }
  }

  Future<void> _togglePause() async {
    if (!_started || _busy || _saving) return;
    setState(() => _busy = true);
    try {
      if (_paused) {
        await _recorder.resume();
        _clock.start();
        if (mounted) setState(() => _paused = false);
      } else {
        await _recorder.pause();
        _clock.stop();
        if (mounted) setState(() => _paused = true);
      }
      try {
        await _recordingNotification.update(
          title: _recordingTitle ??
              tr(widget.preferences, 'Recording', 'Enregistrement'),
          elapsedMs: _clock.elapsedMilliseconds,
          paused: _paused,
        );
      } catch (_) {}
    } catch (error) {
      _showMessage(
          '${tr(widget.preferences, 'Recording control failed', 'Le contrôle de l’enregistrement a échoué')}: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveRecording() async {
    if (!_started || _busy || _saving) return;
    setState(() {
      _saving = true;
      _busy = true;
    });
    try {
      _clock.stop();
      _ticker?.cancel();
      final returnedPath = await _recorder.stop();
      try {
        await _recordingNotification.stop();
      } catch (_) {}
      try {
        await _amplitudeSubscription?.cancel();
      } catch (_) {}
      final path = returnedPath ?? _outputPath;
      if (path == null || !await File(path).exists()) {
        throw const FileSystemException('The recording file was not created.');
      }

      final projectId = _projectId;
      if (projectId == null) throw StateError('Missing project identity.');

      if (_isResume) {
        await _finalizeResume(projectId, path);
      } else {
        await _finalizeFresh(projectId, path);
      }

      _started = false;
      _paused = false;
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _lastError = error;
      if (_isResume) {
        try {
          final partial = _outputPath == null ? null : File(_outputPath!);
          if (partial != null && await partial.exists()) await partial.delete();
        } catch (_) {}
        _showMessage(tr(
          widget.preferences,
          'Could not merge the new take into this recording. The original recording is unchanged. $error',
          'Impossible de fusionner la nouvelle prise dans cet enregistrement. L’enregistrement d’origine est inchangé. $error',
        ));
      } else {
        _showMessage(tr(
          widget.preferences,
          'Could not save this recording: $error',
          'Impossible d’enregistrer ce fichier : $error',
        ));
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _busy = false;
        });
      }
    }
  }

  Future<void> _finalizeFresh(String projectId, String recordedPath) async {
    final draft = widget.repository.projectById(projectId);
    if (draft == null) {
      throw StateError('Recoverable project draft is missing.');
    }
    final sessionId = _sessionId;
    final captureFormat = _captureFormat;
    final captureSampleRate = _captureSampleRate;
    if (sessionId == null || captureFormat == null) {
      throw StateError('Missing recording identity.');
    }
    final targetFormat =
        _normalizeFormat(widget.preferences.recordingFormat.toLowerCase());

    final rawDuration = _clock.elapsedMilliseconds;
    var project = draft.copyWith(
      updatedAt: DateTime.now(),
      sessions: draft.sessions
          .map((session) => session.id == sessionId
              ? session.copyWith(
                  audioPath: recordedPath,
                  durationMs: rawDuration,
                  format: captureFormat,
                  sampleRate: captureSampleRate,
                  recoverablePcm16: captureFormat == 'wav',
                )
              : session)
          .toList(),
      isDraft: false,
      clearMasterAudioPath: true,
    );
    await widget.repository.update(project);

    if (_normalizeFormat(captureFormat) != targetFormat) {
      // Background encoding: the captured file is already committed and fully
      // playable, so hand the transcode to the queue and return immediately.
      // The service swaps the encoded file into the project when it finishes.
      BackgroundEncodeService.instance.enqueueSessionConversion(
        repository: widget.repository,
        project: project,
        sessionId: sessionId,
        inputPath: recordedPath,
        targetFormat: targetFormat,
        bitRate: widget.preferences.bitRate,
        sampleRate: captureSampleRate,
      );
    }
  }

  Future<void> _finalizeResume(String projectId, String newWavPath) async {
    final loaded = widget.repository.projectById(projectId);
    if (loaded == null) {
      throw StateError('Project is missing.');
    }
    var project = loaded;

    final visibility = AudioVisibilityService();

    // Legacy copies (older builds duplicated standalone audio into
    // Music/RAVEN) are removed instead of refreshed — public visibility now
    // MOVES the project folder, so a copied duplicate is pure waste.
    if (project.isStandalone) {
      var cleaned = false;
      if (project.publicFolderLocation != null &&
          AudioVisibilityService.isContentUri(project.publicFolderLocation!)) {
        try {
          await visibility.removeFolder(project.publicFolderLocation!);
        } catch (_) {}
        project = project.copyWith(clearPublicFolderLocation: true);
        cleaned = true;
      }
      if (project.publicCopyLocation != null) {
        try {
          await visibility.remove(project.publicCopyLocation!);
        } catch (_) {}
        project = project.copyWith(clearPublicCopyLocation: true);
        cleaned = true;
      }
      if (cleaned) await widget.repository.update(project);
    }

    final targetId = widget.resumeSessionId;
    final target = project.sessions.firstWhere((s) => s.id == targetId);
    final projectForMerge = project;

    final progress = _MergeProgress();
    try {
      final result = await showDialog<RavenProject>(
        // ignore: use_build_context_synchronously
        context: context,
        barrierDismissible: false,
        builder: (_) => _MergeProgressDialog(
          progress: progress,
          preferences: widget.preferences,
          work: () async {
            // Never race a pending background encode of this project: the merge
            // rewrites the same session record and deletes the old file, and an
            // in-flight encode job holds/replaces the same paths.
            await BackgroundEncodeService.instance.waitForProject(project.id);

            var updated = await _mergeIntoSession(
                projectForMerge, target, newWavPath, progress);

            // No public copy is re-created here: visibility is now purely a
            // folder MOVE managed by ProjectRepository.toggleVisibility, so
            // the merged file already lives in the right place (the project
            // folder never left its location — only the session file was
            // rewritten in-place).
            return updated;
          },
        ),
      );
      if (result == null) {
        throw StateError(
            'The merge did not complete. Your original recording is unchanged.');
      }
    } finally {
      progress.dispose();
    }
  }

  Future<RavenProject> _mergeIntoSession(
    RavenProject project,
    RavenAudioSession target,
    String newWavPath,
    _MergeProgress progress,
  ) async {
    // Standalone recordings have no named project folder — their audio lives
    // flat in the shared sessions store. Use the parent directory of the
    // existing audio file so temp/merged files land in the same location.
    final Directory sessionDir;
    if (project.isStandalone) {
      sessionDir = File(target.audioPath).parent;
    } else {
      final folder = await widget.repository.ensureProjectFolder(project);
      sessionDir = Directory('${folder.path}/sessions');
    }
    await sessionDir.create(recursive: true);

    final targetFormat = target.format.toLowerCase();
    final tempFiles = <String>{newWavPath};

    try {
      String targetWavPath = target.audioPath;
      if (targetFormat != 'wav') {
        progress.update(
          0.05,
          tr(widget.preferences, 'Preparing existing recording…',
              'Préparation de l’enregistrement existant…'),
        );
        final wavPath = '${sessionDir.path}/tmp-target-${const Uuid().v4()}.wav';
        tempFiles.add(wavPath);
        await AudioMergeService().convertToFormat(
          input: File(target.audioPath),
          outputPath: wavPath,
          format: 'wav',
          sampleRate: target.sampleRate,
          estimatedDuration: Duration(milliseconds: target.durationMs),
          onProgress: (p) => progress.update(
            0.05 + p * 0.2,
            tr(widget.preferences, 'Converting to WAV…',
                'Conversion en WAV…'),
          ),
        );
        targetWavPath = wavPath;
      }

      progress.update(0.3, tr(widget.preferences, 'Merging…', 'Fusion…'));
      final merged = await AudioMergeService().mergeWavSessions(
        sessions: <RavenAudioSession>[
          RavenAudioSession(
            id: target.id,
            audioPath: targetWavPath,
            createdAt: target.createdAt,
            durationMs: target.durationMs,
            format: 'wav',
            sampleRate: target.sampleRate,
          ),
          RavenAudioSession(
            id: 'tmp-new',
            audioPath: newWavPath,
            createdAt: DateTime.now(),
            durationMs: 0,
            format: 'wav',
            sampleRate: target.sampleRate,
          ),
        ],
        sessionsDirectory: sessionDir,
        preferredFileName: 'tmp-merged-${const Uuid().v4()}.wav',
        onProgress: (p) => progress.update(
          0.3 + p * 0.15,
          tr(widget.preferences, 'Merging…', 'Fusion…'),
        ),
      );
      tempFiles.add(merged.file.path);

      progress.update(
        0.5,
        tr(widget.preferences, 'Encoding ${targetFormat.toUpperCase()}…',
            'Encodage ${targetFormat.toUpperCase()}…'),
      );
      final finalPath =
          '${sessionDir.path}/recording-${target.id}-${DateTime.now().millisecondsSinceEpoch}.$targetFormat';
      tempFiles.add(finalPath);
      if (targetFormat == 'wav') {
        await merged.file.copy(finalPath);
      } else {
        await AudioMergeService().convertToFormat(
          input: merged.file,
          outputPath: finalPath,
          format: targetFormat,
          bitRate: target.bitRate, // BITRATE: preserve original tier
          sampleRate: target.sampleRate,
          estimatedDuration: Duration(milliseconds: merged.durationMs),
          onProgress: (p) => progress.update(
            0.5 + p * 0.4,
            tr(widget.preferences, 'Encoding ${targetFormat.toUpperCase()}…',
                'Encodage ${targetFormat.toUpperCase()}…'),
          ),
        );
      }

      progress.update(
          0.95, tr(widget.preferences, 'Finalizing…', 'Finalisation…'));
      final updatedSession = target.copyWith(
        audioPath: finalPath,
        durationMs: merged.durationMs,
      );
      final updatedProject = project.copyWith(
        sessions: project.sessions
            .map((s) => s.id == target.id ? updatedSession : s)
            .toList(),
        updatedAt: DateTime.now(),
      );
      await widget.repository.update(updatedProject);
      tempFiles.remove(finalPath);

      try {
        final oldFile = File(target.audioPath);
        if (await oldFile.exists()) await oldFile.delete();
      } on FileSystemException {
        // Deleting the old file is best-effort; the merged file is authoritative.
      }

      progress.update(1.0, tr(widget.preferences, 'Done', 'Terminé'));
      return updatedProject;
    } finally {
      for (final p in tempFiles) {
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } on FileSystemException {
          // Temp cleanup is best-effort.
        }
      }
    }
  }

  String _normalizeFormat(String format) {
    final f = format.toLowerCase();
    return (f == 'aac') ? 'm4a' : f;
  }

  Future<void> _discardRecording({bool close = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_started) {
        try {
          await _recorder.stop();
        } catch (_) {}
        try {
          await _recordingNotification.stop();
        } catch (_) {}
      }
      _ticker?.cancel();
      try {
        await _amplitudeSubscription?.cancel();
      } catch (_) {}

      if (_isResume) {
        final partial = _outputPath == null ? null : File(_outputPath!);
        try {
          if (partial != null && await partial.exists()) {
            await partial.delete();
          }
        } catch (_) {}
      } else {
        final id = _projectId;
        if (id != null) {
          if (widget.existingProject != null) {
            try {
              await widget.repository.update(widget.existingProject!);
            } catch (_) {}
            final partial = _outputPath == null ? null : File(_outputPath!);
            try {
              if (partial != null && await partial.exists()) {
                await partial.delete();
              }
            } catch (_) {}
          } else {
            final draft = widget.repository.projectById(id);
            if (draft != null) {
              try {
                await widget.repository.deleteForever(draft);
              } catch (_) {}
            }
          }
        }
      }
      _clock.stop();
      _started = false;
      _paused = false;
      if (close && mounted) Navigator.of(context).pop();
    } catch (error) {
      _showMessage(
          '${tr(widget.preferences, 'Could not discard recording', 'Impossible d’annuler l’enregistrement')}: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _requestExit() async {
    if (_busy && !_started) return false;
    if (!_hasUnsavedRecording) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Discard recording?',
            'Annuler l’enregistrement ?')),
        content: Text(_isResume
            ? tr(
                widget.preferences,
                'The new take will be deleted. Your original recording stays unchanged.',
                'La nouvelle prise sera supprimée. Votre enregistrement d’origine reste inchangé.')
            : tr(
                widget.preferences,
                'The audio that has not been saved will be deleted.',
                'L’audio non enregistré sera supprimé.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child:
                Text(tr(widget.preferences, 'Keep recording', 'Continuer')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(widget.preferences, 'Discard', 'Annuler')),
          ),
        ],
      ),
    );
    if (discard == true) {
      await _discardRecording(close: false);
      return true;
    }
    return false;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        final shouldClose = await _requestExit();
        if (!context.mounted) return;
        if (shouldClose) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: tr(widget.preferences, 'Close recorder',
                'Fermer l’enregistreur'),
            onPressed: () async {
              final shouldClose = await _requestExit();
              if (!context.mounted) return;
              if (shouldClose) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.close_rounded),
          ),
          title: Text(_isResume
              ? tr(widget.preferences, 'Resume recording',
                  'Reprendre l’enregistrement')
              : tr(widget.preferences, 'New recording',
                  'Nouvel enregistrement')),
          centerTitle: true,
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxHeight < 600;
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      isCompact ? 16 : 24,
                      isCompact ? 8 : 12,
                      isCompact ? 16 : 24,
                      isCompact ? 12 : 28,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        Container(
                          width: isCompact ? 72 : 92,
                          height: isCompact ? 72 : 92,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: accent.withValues(alpha: 0.35)),
                          ),
                          child: Icon(Icons.graphic_eq_rounded,
                              size: isCompact ? 36 : 44, color: accent),
                        ),
                        SizedBox(height: isCompact ? 10 : 24),
                        Text(
                          _paused
                              ? tr(widget.preferences, 'Recording paused',
                                  'Enregistrement en pause')
                              : _started
                                  ? tr(widget.preferences,
                                      'Recording in progress',
                                      'Enregistrement en cours')
                                  : tr(widget.preferences,
                                      'Preparing microphone…',
                                      'Préparation du microphone…'),
                          style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          label: tr(widget.preferences, 'Elapsed time',
                              'Temps écoulé'),
                          child: Text(
                            _elapsed,
                            style: theme.textTheme.displayMedium?.copyWith(
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures()
                              ],
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        SizedBox(height: isCompact ? 8 : 20),
                        SizedBox(
                          height: isCompact ? 56 : 76,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children:
                                List<Widget>.generate(_levels.length, (index) {
                              final level = _paused ? 0.10 : _levels[index];
                              final waveColor = Color.lerp(
                                accent,
                                theme.colorScheme.tertiary,
                                level.clamp(0, 1).toDouble(),
                              )!;
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 140),
                                curve: Curves.easeOutCubic,
                                width: isCompact ? 3.2 : 4,
                                height: 7 + (level * (isCompact ? 46 : 64)),
                                decoration: BoxDecoration(
                                  color: waveColor.withValues(
                                      alpha: _paused
                                          ? 0.35
                                          : 0.55 + level * 0.45),
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: level > 0.55 && !_paused
                                      ? <BoxShadow>[
                                          BoxShadow(
                                            color: waveColor.withValues(
                                                alpha: 0.35),
                                            blurRadius: 8,
                                            spreadRadius: 1,
                                          ),
                                        ]
                                      : null,
                                ),
                              );
                            }),
                          ),
                        ),
                        SizedBox(height: isCompact ? 8 : 18),
                        Text(
                          _lastError == null
                              ? tr(widget.preferences,
                                  'Saved privately on this device',
                                  'Enregistré en privé sur cet appareil')
                              : tr(widget.preferences,
                                  'Visualization is unavailable; recording can continue.',
                                  'Visualisation indisponible ; l’enregistrement peut continuer.'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: <Widget>[
                            _RoundAction(
                              icon: Icons.delete_outline_rounded,
                              label: tr(
                                  widget.preferences, 'Discard', 'Annuler'),
                              onPressed: (!_started || _busy)
                                  ? null
                                  : () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (dialogContext) => AlertDialog(
                                          title: Text(tr(
                                              widget.preferences,
                                              'Discard recording?',
                                              'Annuler l’enregistrement ?')),
                                          content: Text(tr(
                                              widget.preferences,
                                              'This recording will be deleted.',
                                              'Cet enregistrement sera supprimé.')),
                                          actions: <Widget>[
                                            TextButton(
                                                onPressed: () => Navigator.pop(
                                                    dialogContext, false),
                                                child: Text(tr(
                                                    widget.preferences,
                                                    'Keep',
                                                    'Garder'))),
                                            FilledButton(
                                                onPressed: () => Navigator.pop(
                                                    dialogContext, true),
                                                child: Text(tr(
                                                    widget.preferences,
                                                    'Discard',
                                                    'Annuler'))),
                                          ],
                                        ),
                                      );
                                      if (confirmed == true) {
                                        await _discardRecording();
                                      }
                                    },
                            ),
                            GestureDetector(
                              onTap:
                                  (!_started || _busy) ? null : _togglePause,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                width: isCompact ? 72 : 88,
                                height: isCompact ? 72 : 88,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: accent,
                                  boxShadow: <BoxShadow>[
                                    BoxShadow(
                                        color: accent.withValues(alpha: 0.28),
                                        blurRadius: 26,
                                        spreadRadius: 2),
                                  ],
                                ),
                                child: _busy
                                    ? const Padding(
                                        padding: EdgeInsets.all(28),
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.4))
                                    : Icon(
                                        _paused
                                            ? Icons.play_arrow_rounded
                                            : Icons.pause_rounded,
                                        size: 42,
                                        color: theme.colorScheme.onPrimary),
                              ),
                            ),
                            _RoundAction(
                              icon: Icons.check_rounded,
                              label: tr(widget.preferences, 'Save',
                                  'Enregistrer'),
                              isPrimary: true,
                              onPressed: (!_started || _busy || _saving)
                                  ? null
                                  : _saveRecording,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isPrimary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 78,
      child: Column(
        children: <Widget>[
          IconButton.filledTonal(
            onPressed: onPressed,
            icon: Icon(icon),
            iconSize: 26,
            style: IconButton.styleFrom(
              fixedSize: const Size(54, 54),
              backgroundColor:
                  isPrimary ? theme.colorScheme.primaryContainer : null,
              foregroundColor:
                  isPrimary ? theme.colorScheme.onPrimaryContainer : null,
            ),
          ),
          const SizedBox(height: 7),
          Text(label,
              textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _MergeProgress {
  final ValueNotifier<double> value = ValueNotifier<double>(0.0);
  final ValueNotifier<String> label = ValueNotifier<String>('');

  void update(double v, String l) {
    value.value = v.clamp(0.0, 1.0).toDouble();
    label.value = l;
  }

  void dispose() {
    value.dispose();
    label.dispose();
  }
}

class _MergeProgressDialog extends StatefulWidget {
  const _MergeProgressDialog({
    required this.progress,
    required this.preferences,
    required this.work,
  });

  final _MergeProgress progress;
  final AppPreferences preferences;
  final Future<RavenProject> Function() work;

  @override
  State<_MergeProgressDialog> createState() => _MergeProgressDialogState();
}

class _MergeProgressDialogState extends State<_MergeProgressDialog> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final result = await widget.work();
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(_error == null
            ? tr(widget.preferences, 'Processing recording',
                'Traitement de l’enregistrement')
            : tr(widget.preferences, 'Processing failed',
                'Échec du traitement')),
        content: _error == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(height: 8),
                  ValueListenableBuilder<double>(
                    valueListenable: widget.progress.value,
                    builder: (_, v, __) => SizedBox(
                      width: 96,
                      height: 96,
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          SizedBox(
                            width: 96,
                            height: 96,
                            child: CircularProgressIndicator(
                              value: v > 0 ? v : null,
                              strokeWidth: 6,
                            ),
                          ),
                          Text(
                            '${(v * 100).round()}%',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ValueListenableBuilder<String>(
                    valueListenable: widget.progress.label,
                    builder: (_, label, __) => Text(
                      label.isEmpty ? '…' : label,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('$_error'),
                  const SizedBox(height: 12),
                  Text(
                    tr(
                      widget.preferences,
                      'Your original recordings are safe. Tap Close to return.',
                      'Vos enregistrements d’origine sont en sécurité. Touchez Fermer pour revenir.',
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
        actions: _error != null
            ? <Widget>[
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: Text(tr(widget.preferences, 'Close', 'Fermer')),
                ),
              ]
            : null,
      ),
    );
  }
}