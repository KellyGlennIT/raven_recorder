import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';
import '../services/project_repository.dart';
import '../services/audio_merge_service.dart';
import '../services/recording_notification_service.dart';
import '../services/wav_recovery_service.dart';
import '../services/audio_visibility_service.dart';

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({
    required this.repository,
    required this.preferences,
    required this.onSaved,
    this.continueProject,
    this.initialTitle,
    this.createProject = true,
    super.key,
  });

  final ProjectRepository repository;
  final AppPreferences preferences;
  final VoidCallback onSaved;

  /// When set, this recording becomes another session in the existing project.
  final RavenProject? continueProject;

  /// Optional display title for a user-created scheduled recording.
  final String? initialTitle;

  /// Controls whether a fresh recording starts as a new project or a single take.
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
  int _lastNotificationSecond = -1;
  DateTime? _startedAt;
  Object? _lastError;

  bool get _hasUnsavedRecording => _started;

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
    RecordingNotificationService.setActionHandler(null);
    _recorder.dispose();
    super.dispose();
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

      final existingProject = widget.continueProject;
      if (existingProject?.isAudioProtected == true) {
        throw StateError(
            'Decrypt this project before adding another recording session.');
      }
      final projectId = existingProject?.id ?? widget.repository.newId();
      final shouldCreateProject =
          existingProject != null || widget.createProject;
      final sessionId = const Uuid().v4();
      final createdAt = DateTime.now();
      final projectDirectory = shouldCreateProject
          ? (existingProject == null
              ? await widget.repository.createProjectDirectory(projectId)
              : Directory(
                  '${widget.repository.projectsDirectory.path}/$projectId'))
          : Directory('${widget.repository.projectsDirectory.path}/$projectId');
      await projectDirectory.create(recursive: true);
      final sessionDirectory = Directory('${projectDirectory.path}/sessions');
      await sessionDirectory.create(recursive: true);
      // Keep the active capture as PCM WAV so an interrupted process can be
      // recovered even when the selected final export format is compressed.
      const extension = 'wav';
      final filePath = '${sessionDirectory.path}/$sessionId.$extension';
      _projectId = projectId;
      _sessionId = sessionId;
      _outputPath = filePath;
      _startedAt = createdAt;
      final titleStamp =
          DateFormat('dd MMM yyyy, HH:mm', 'en').format(createdAt);
      final scheduledTitle = widget.initialTitle?.trim();
      final draftTitle = existingProject?.title ??
          (scheduledTitle != null && scheduledTitle.isNotEmpty
              ? scheduledTitle
              : '${tr(widget.preferences, 'Recording', 'Enregistrement')} — $titleStamp');
      _recordingTitle = draftTitle;
      final newSession = RavenAudioSession(
        id: sessionId,
        audioPath: filePath,
        createdAt: createdAt,
        durationMs: 0,
        format: extension,
        sampleRate: widget.preferences.sampleRate,
        recoverablePcm16: true,
      );
      // Persist a recoverable draft before starting the microphone. Continuing a
      // project preserves every prior session and only appends this new session.
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
                newSession
              ],
              isDraft: true,
              clearMasterAudioPath: true,
            );
      if (existingProject == null) {
        await widget.repository.add(draft);
      } else {
        await widget.repository.update(draft);
      }

      await _recorder.start(
        RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: widget.preferences.sampleRate,
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
        // Amplitude visualization is optional; recording must continue if it fails.
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
          if (path != null) {
            final draft = _projectId == null
                ? null
                : widget.repository.projectById(_projectId!);
            final sessionId = _sessionId;
            if (draft != null && sessionId != null) {
              final duration = await WavRecoveryService().repairPcm16File(
                File(path),
                sampleRate: widget.preferences.sampleRate,
              );
              if (duration != null) {
                final sessions = draft.sessions
                    .map((session) => session.id == sessionId
                        ? session.copyWith(
                            audioPath: path,
                            durationMs: duration,
                            recoverablePcm16: true,
                            sampleRate: widget.preferences.sampleRate,
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
      } catch (_) {
        // The recorder must still be preserved if Android cannot dismiss its notification.
      }
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
          if (widget.continueProject != null) {
            final original = widget.continueProject!;
            await widget.repository.update(original);
            final partial = _outputPath == null ? null : File(_outputPath!);
            if (partial != null && await partial.exists()) {
              await partial.delete();
            }
          } else {
            final draft = widget.repository.projectById(id);
            if (draft != null) {
              await widget.repository.deleteForever(draft);
            } else {
              final directory =
                  Directory('${widget.repository.projectsDirectory.path}/$id');
              if (await directory.exists()) {
                await directory.delete(recursive: true);
              }
            }
          }
        } catch (_) {
          // Best-effort cleanup; the app must still return to the previous screen.
        }
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      await _recordingNotification.update(
        title: _recordingTitle ??
            tr(widget.preferences, 'Recording', 'Enregistrement'),
        elapsedMs: _clock.elapsedMilliseconds,
        paused: _paused,
      );
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
      await _recordingNotification.stop();
      await _amplitudeSubscription?.cancel();
      final path = returnedPath ?? _outputPath;
      if (path == null || !await File(path).exists()) {
        throw const FileSystemException('The recording file was not created.');
      }

      final createdAt = _startedAt ?? DateTime.now();
      final projectId = _projectId;
      final sessionId = _sessionId;
      if (projectId == null || sessionId == null) {
        throw StateError('Missing recording identity.');
      }
      final draft = widget.repository.projectById(projectId);
      if (draft == null) {
        throw StateError('Recoverable project draft is missing.');
      }
      // Continuing clears the master pointer while source sessions are appended.
      // Keep the previous file until this new source session is durably committed.
      final previousMasterPath = widget.continueProject?.masterAudioPath;
      final previousPublicCopy = widget.continueProject?.publicCopyLocation;
      var project = draft.copyWith(
        title: widget.continueProject?.title ??
            ((widget.initialTitle?.trim().isNotEmpty ?? false)
                ? widget.initialTitle!.trim()
                : '${tr(widget.preferences, 'Recording', 'Enregistrement')} — ${DateFormat('dd MMM yyyy, HH:mm', 'en').format(createdAt)}'),
        updatedAt: DateTime.now(),
        sessions: draft.sessions
            .map((session) => session.id == sessionId
                ? session.copyWith(
                    audioPath: path,
                    durationMs: _clock.elapsedMilliseconds,
                    format: 'wav',
                    sampleRate: widget.preferences.sampleRate,
                    recoverablePcm16: true,
                  )
                : session)
            .toList(),
        isDraft: false,
        clearMasterAudioPath: true,
      );
      // First commit the new source session. If merging fails or the app is
      // interrupted, the original segments remain playable and recoverable.
      await widget.repository.update(project);
      try {
        final sessionDirectory = Directory(
            '${widget.repository.projectsDirectory.path}/$projectId/sessions');
        final master = await AudioMergeService().mergeProject(
          sessions: project.sessions,
          outputDirectory: sessionDirectory,
          projectId: projectId,
          format: widget.preferences.recordingFormat,
          bitRate: widget.preferences.bitRate,
          sampleRate: widget.preferences.sampleRate,
        );
        project = project.copyWith(masterAudioPath: master.path);
        await widget.repository.update(project);
        if (project.isAudioProtected || project.requiresAppPin) {
          _showMessage(tr(
            widget.preferences,
            'Merged audio was saved privately because this recording is protected.',
            'L’audio fusionné a été enregistré en privé, car cet enregistrement est protégé.',
          ));
        } else {
          try {
            project = await _publishMergedAudio(
              project,
              previousPublicCopy: previousPublicCopy,
            );
          } catch (publishError) {
            _showMessage(tr(
              widget.preferences,
              'Merged audio is saved in RAVEN, but its public copy could not be updated: $publishError',
              'L’audio fusionné est enregistré dans RAVEN, mais sa copie publique n’a pas pu être mise à jour : $publishError',
            ));
          }
        }
      } catch (mergeError) {
        // Keep the successful recording even if an optional master rebuild fails.
        _showMessage(tr(
            widget.preferences,
            'Recording saved. RAVEN will play the parts in sequence because the master merge could not finish: $mergeError',
            'Enregistrement sauvegardé. RAVEN lira les parties à la suite, car la fusion principale n’a pas abouti : $mergeError'));
      }
      // The segment files are now the durable source of truth and the project
      // index no longer refers to the old master. Clean it up only after commit;
      // do not delete a path that the new project is still using.
      if (previousMasterPath != null &&
          previousMasterPath != project.masterAudioPath) {
        try {
          final previousMaster = File(previousMasterPath);
          if (await previousMaster.exists()) await previousMaster.delete();
        } on FileSystemException {
          // An orphaned old master is harmless; cleanup is best-effort.
        }
      }
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _lastError = error;
      _showMessage(
          '${tr(widget.preferences, 'Could not save this recording', 'Impossible d’enregistrer ce fichier')}: $error');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _busy = false;
        });
      }
    }
  }

  Future<RavenProject> _publishMergedAudio(
    RavenProject project, {
    String? previousPublicCopy,
  }) async {
    final visibility = AudioVisibilityService();
    final location = await visibility.publish(
      source: File(project.masterAudioPath!),
      title: project.title,
      projectId: project.id,
    );
    final published = project.copyWith(publicCopyLocation: location);
    try {
      await widget.repository.update(published);
    } catch (error) {
      try {
        await visibility.remove(location);
      } catch (cleanupError) {
        throw StateError(
            '$error The new public copy could not be cleaned up: $cleanupError');
      }
      rethrow;
    }
    if (previousPublicCopy != null && previousPublicCopy != location) {
      try {
        await visibility.remove(previousPublicCopy);
      } catch (cleanupError) {
        _showMessage(tr(
          widget.preferences,
          'The new merged audio was published, but its previous public copy could not be removed: $cleanupError',
          'Le nouvel audio fusionné a été publié, mais l’ancienne copie publique n’a pas pu être supprimée : $cleanupError',
        ));
      }
    }
    return published;
  }

  Future<void> _discardRecording({bool close = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_started) {
        try {
          await _recorder.stop();
        } catch (_) {
          // Continue cleanup even if the recorder already stopped itself.
        }
        await _recordingNotification.stop();
      }
      _ticker?.cancel();
      await _amplitudeSubscription?.cancel();
      final id = _projectId;
      if (id != null) {
        if (widget.continueProject != null) {
          await widget.repository.update(widget.continueProject!);
          final partial = _outputPath == null ? null : File(_outputPath!);
          if (partial != null && await partial.exists()) await partial.delete();
        } else {
          final draft = widget.repository.projectById(id);
          if (draft != null) {
            await widget.repository.deleteForever(draft);
          } else {
            final directory =
                Directory('${widget.repository.projectsDirectory.path}/$id');
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          }
        }
      }
      _clock.stop();
      if (close && mounted) Navigator.of(context).pop();
    } catch (error) {
      _showMessage(
          '${tr(widget.preferences, 'Could not discard recording', 'Impossible d’annuler l’enregistrement')}: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _requestExit() async {
    // Startup is asynchronous (permission, directory and encoder setup). Keeping
    // the route mounted until it settles prevents a recording from starting
    // after its UI has already been dismissed.
    if (_busy && !_started) return false;
    if (!_hasUnsavedRecording) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Discard recording?',
            'Annuler l’enregistrement ?')),
        content: Text(tr(
            widget.preferences,
            'The audio that has not been saved will be deleted.',
            'L’audio non enregistré sera supprimé.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(widget.preferences, 'Keep recording', 'Continuer')),
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
            tooltip: tr(
                widget.preferences, 'Close recorder', 'Fermer l’enregistreur'),
            onPressed: () async {
              final shouldClose = await _requestExit();
              if (!context.mounted) return;
              if (shouldClose) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.close_rounded),
          ),
          title: Text(
              tr(widget.preferences, 'New recording', 'Nouvel enregistrement')),
          centerTitle: true,
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxHeight < 600;
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
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
                                  ? tr(
                                      widget.preferences,
                                      'Recording in progress',
                                      'Enregistrement en cours')
                                  : tr(
                                      widget.preferences,
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
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 100),
                                width: 3.2,
                                height: 8 + (level * (isCompact ? 46 : 64)),
                                decoration: BoxDecoration(
                                  color: accent.withValues(
                                      alpha: 0.35 + (level * 0.65)),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              );
                            }),
                          ),
                        ),
                        SizedBox(height: isCompact ? 8 : 18),
                        Text(
                          _lastError == null
                              ? tr(
                                  widget.preferences,
                                  'Saved privately on this device',
                                  'Enregistré en privé sur cet appareil')
                              : tr(
                                  widget.preferences,
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
                              label:
                                  tr(widget.preferences, 'Discard', 'Annuler'),
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
                              onTap: (!_started || _busy) ? null : _togglePause,
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
                              label:
                                  tr(widget.preferences, 'Save', 'Enregistrer'),
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
