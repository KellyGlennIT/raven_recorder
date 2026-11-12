import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';
import '../services/playback_service.dart';

class StandaloneRecordingScreen extends StatefulWidget {
  const StandaloneRecordingScreen({
    required this.project,
    required this.preferences,
    required this.onResume,
    required this.onCreateProject,
    required this.onShare,
    required this.onRename,
    required this.onToggleEncryption,
    required this.onToggleVisibility,
    required this.onSaveAmplified,
    this.onTrim,
    this.onTogglePin,
    this.onOpenDetails,
    this.autoPlay = false,
    super.key,
  });

  final RavenProject project;
  final AppPreferences preferences;
  final VoidCallback onResume;
  final VoidCallback onCreateProject;
  final Future<void> Function() onShare;
  final Future<bool> Function(String title) onRename;
  final Future<void> Function() onToggleEncryption;
  final Future<String?> Function() onToggleVisibility;
  final Future<void> Function()? onTogglePin;
  final Future<bool> Function(RavenProject updated) onSaveAmplified;
  final Future<void> Function()? onTrim;
  final VoidCallback? onOpenDetails;
  final bool autoPlay;

  @override
  State<StandaloneRecordingScreen> createState() =>
      _StandaloneRecordingScreenState();
}

class _StandaloneRecordingScreenState extends State<StandaloneRecordingScreen> {
  AudioPlayer get _player => PlaybackService().player;
  late RavenProject _currentProject;
  late String _title;
  late bool _requiresPin;
  late bool _isProtected;
  String? _publicCopyLocation;
  String? _error;
  bool _loading = true;
  bool _loadingInProgress = false;
  bool _savingAmplified = false;
  double _volumeBoost = 1.0;
  double _speed = 1.0;
  bool _boostProcessing = false;
  String? _boostedPath;

  @override
  void initState() {
    super.initState();
    _currentProject = widget.project;
    _title = _currentProject.title;
    _requiresPin = _currentProject.requiresAppPin;
    _isProtected = _currentProject.isAudioProtected;
    _publicCopyLocation = _currentProject.publicFolderLocation ??
        _currentProject.publicCopyLocation;
    try {
      _player.setVolume(1.0);
      _player.setSpeed(1.0);
    } catch (_) {}
    _cleanupOrphanBoostFiles();
    _loadAudio();
  }

  @override
  void dispose() {
    final path = _boostedPath;
    if (path != null) {
      try {
        _player.stop();
      } catch (_) {}
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    try {
      _player.setVolume(1.0);
      _player.setSpeed(1.0);
    } catch (_) {}
    super.dispose();
  }

  Future<void> _cleanupOrphanBoostFiles() async {
    try {
      final cache = await getTemporaryDirectory();
      final dir = Directory(cache.path);
      if (!await dir.exists()) return;
      final prefix = 'raven-boost-${_currentProject.id}-';
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith(prefix)) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<Uri?> _artUri() async {
    try {
      final temp = await getTemporaryDirectory();
      final cached = File('${temp.path}/raven_notification_logo.png');
      if (!await cached.exists()) {
        final bytes = await rootBundle.load('assets/images/raven_logo.png');
        await cached.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      }
      return Uri.file(cached.path);
    } catch (_) {
      return null;
    }
  }

  Future<MediaItem> _mediaItemFor(
    RavenAudioSession session, {
    required bool boosted,
  }) async {
    Uri? artUri;
    try {
      artUri = await _artUri().timeout(
        const Duration(milliseconds: 400),
        onTimeout: () => null,
      );
    } catch (_) {}
    return MediaItem(
      id: boosted ? '${_currentProject.id}-boost' : _currentProject.id,
      title: _title,
      album: 'RAVEN',
      duration: Duration(milliseconds: session.durationMs),
      artUri: artUri,
    );
  }

  Future<void> _loadAudio() async {
    if (_isProtected) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (_loadingInProgress) return;
    _loadingInProgress = true;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final masterPath = _currentProject.masterAudioPath;
      final masterExists =
          masterPath != null && await File(masterPath).exists();
      if (_currentProject.sessions.isEmpty && !masterExists) {
        _error = tr(
            widget.preferences,
            'This standalone recording has no audio yet.',
            'Cet enregistrement ne contient pas encore d’audio.');
        return;
      }

      try {
        await _player.stop().timeout(const Duration(seconds: 2));
      } catch (_) {}

      final session = _currentProject.sessions.isNotEmpty
          ? _currentProject.sessions.first
          : null;

      if (masterExists && session != null) {
        await _loadSourceFromPath(masterPath, session, boosted: false);
      } else if (session != null) {
        await _loadSource(session, boosted: false);
      } else {
        throw StateError('This standalone recording has no audio yet.');
      }

      if (widget.autoPlay && mounted) {
        unawaited(_player.play());
      }
    } catch (error) {
      _error = error.toString();
    } finally {
      _loadingInProgress = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadSource(RavenAudioSession session,
      {required bool boosted}) async {
    return _loadSourceFromPath(session.audioPath, session, boosted: boosted);
  }

  Future<void> _loadSourceFromPath(String path, RavenAudioSession session,
      {required bool boosted}) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Recording file is missing', path);
    }
    if (await file.length() < 64) {
      throw StateError('Recording file is empty or too small to play.');
    }
    final mediaItem = await _mediaItemFor(session, boosted: boosted);
    await _player
        .setAudioSource(
          AudioSource.uri(Uri.file(path), tag: mediaItem),
          initialPosition: Duration.zero,
        )
        .timeout(const Duration(seconds: 15));
    await _player.setVolume(1.0);
    await _player.setSpeed(_speed);
  }

  String _boostExt(String format) {
    final f = format.toLowerCase();
    return switch (f) {
      'wav' => 'wav',
      'flac' => 'flac',
      'mp3' => 'mp3',
      _ => 'm4a',
    };
  }

  /// Codec args for the FFmpeg amplify pass, at the session's own bitrate.
  ///
  /// - WAV: pcm_s16le, no bitrate (lossless PCM).
  /// - FLAC: flac, no bitrate (lossless).
  /// - MP3: libmp3lame at `bitRate` from the session.
  /// - M4A: aac at `bitRate` from the session.
  String _boostCodec(String ext, int bitRate) {
    final clamped = bitRate.clamp(64000, 320000);
    return switch (ext) {
      'wav' => '-c:a pcm_s16le',
      'flac' => '-c:a flac',
      'mp3' => '-c:a libmp3lame -b:a $clamped',
      _ => '-c:a aac -b:a $clamped -movflags +faststart',
    };
  }

  Future<void> _deleteBoostedFile() async {
    final path = _boostedPath;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      _boostedPath = null;
    }
  }

  Future<void> _applyBoost(double level) async {
    if (_boostProcessing || _isProtected) return;
    if (level == _volumeBoost) return;

    final session = _currentProject.sessions.isNotEmpty
        ? _currentProject.sessions.first
        : null;
    if (session == null) return;

    setState(() => _boostProcessing = true);
    final wasPlaying = _player.playing;
    final pos = _player.position;
    final oldBoost = _boostedPath;

    try {
      await _player.pause();

      if (level <= 1.0) {
        try {
          await _player.stop().timeout(const Duration(seconds: 2));
        } catch (_) {}
        await _loadSource(session, boosted: false);
        _boostedPath = null;
        if (oldBoost != null) {
          try {
            final f = File(oldBoost);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
        if (pos > Duration.zero) {
          try {
            await _player.seek(pos);
          } catch (_) {}
        }
        if (wasPlaying) unawaited(_player.play());
        if (mounted) {
          setState(() {
            _volumeBoost = 1.0;
            _boostProcessing = false;
          });
        }
        return;
      }

      final source = File(session.audioPath);
      if (!await source.exists()) {
        throw StateError('Recording file is missing');
      }

      final cache = await getTemporaryDirectory();
      final ext = _boostExt(session.format);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final newPath =
          '${cache.path}/raven-boost-${_currentProject.id}-$stamp.$ext';
      final outFile = File(newPath);
      if (await outFile.exists()) {
        try {
          await outFile.delete();
        } catch (_) {}
      }

      final codec = _boostCodec(ext, session.bitRate); // BITRATE
      final sampleRate = session.sampleRate > 0 ? session.sampleRate : 44100;
      final command = '-hide_banner -nostdin -y '
          '-i "${source.path}" '
          '-ar $sampleRate '
          '-af "volume=${level.toStringAsFixed(2)},alimiter=limit=0.95:attack=5:release=50" '
          '$codec "$newPath"';

      var ffSession = await FFmpegKit.execute(command);
      var code = await ffSession.getReturnCode();
      if (!ReturnCode.isSuccess(code) && command.contains('-c:a libmp3lame')) {
        final fallbackCommand = command.replaceFirst('-c:a libmp3lame', '-c:a mp3');
        ffSession = await FFmpegKit.execute(fallbackCommand);
        code = await ffSession.getReturnCode();
      }
      if (!ReturnCode.isSuccess(code)) {
        final logs = await ffSession.getOutput();
        try {
          if (await outFile.exists()) await outFile.delete();
        } catch (_) {}
        throw StateError(
            'FFmpeg failed: ${logs ?? code?.getValue() ?? 'unknown'}');
      }
      if (!await outFile.exists() || await outFile.length() < 64) {
        try {
          if (await outFile.exists()) await outFile.delete();
        } catch (_) {}
        throw StateError('Boost produced empty output');
      }

      await _loadSourceFromPath(newPath, session, boosted: true);
      _boostedPath = newPath;

      if (oldBoost != null) {
        try {
          final f = File(oldBoost);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      if (pos > Duration.zero) {
        try {
          await _player.seek(pos);
        } catch (_) {}
      }
      if (wasPlaying) unawaited(_player.play());
      if (mounted) {
        setState(() {
          _volumeBoost = level;
          _boostProcessing = false;
        });
      }
    } catch (e) {
      try {
        await _loadSource(session, boosted: false);
        _volumeBoost = 1.0;
        final toDelete = _boostedPath;
        _boostedPath = null;
        if (toDelete != null) {
          try {
            final f = File(toDelete);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      } catch (_) {}

      if (mounted) {
        setState(() => _boostProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Could not amplify audio: $e',
            'Impossible d’amplifier l’audio : $e',
          )),
        ));
      }
    }
  }

  Future<void> _saveAmplifiedAsRecording() async {
    if (_savingAmplified || _boostProcessing) return;
    final boostedPath = _boostedPath;
    if (boostedPath == null || _isProtected) return;
    final session = _currentProject.sessions.isNotEmpty
        ? _currentProject.sessions.first
        : null;
    if (session == null) return;

    setState(() => _savingAmplified = true);
    final messenger = ScaffoldMessenger.of(context);
    final oldPath = session.audioPath;
    String? newPath;
    var copiedBoost = false;
    var committed = false;

    try {
      await _player.pause();

      final boostFile = File(boostedPath);
      if (!await boostFile.exists()) {
        throw StateError('Amplified file is no longer available');
      }

      final originalFile = File(oldPath);
      final parentDir = originalFile.parent;
      await parentDir.create(recursive: true);

      final ext = _boostExt(session.format);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      newPath = '${parentDir.path}/amplified-$stamp.$ext';
      await boostFile.copy(newPath);
      copiedBoost = true;

      final copied = File(newPath);
      if (!await copied.exists() || await copied.length() < 64) {
        throw StateError('Copy of the amplified audio failed');
      }

      int newDurationMs = session.durationMs;
      if (newDurationMs <= 0) {
        final probe = AudioPlayer();
        try {
          await probe.setAudioSource(
            AudioSource.uri(
              Uri.file(newPath),
              tag: MediaItem(
                  id: 'probe-${_currentProject.id}', title: _title),
            ),
          );
          newDurationMs = probe.duration?.inMilliseconds ?? 0;
        } finally {
          await probe.dispose();
        }
      }

      // Format and bitrate are preserved from the session — copyWith keeps
      // bitRate as-is (the source audio was already encoded at that tier).
      final updatedSession = session.copyWith(
        audioPath: newPath,
        durationMs: newDurationMs,
        format: ext,
      );
      final updatedProject = _currentProject.copyWith(
        sessions: <RavenAudioSession>[updatedSession],
        updatedAt: DateTime.now(),
      );

      final ok = await widget.onSaveAmplified(updatedProject);
      if (!ok) {
        throw StateError('Could not update the library');
      }
      committed = true;

      _currentProject = updatedProject;
      _boostedPath = null;
      _volumeBoost = 1.0;

      try {
        await _player.stop().timeout(const Duration(seconds: 2));
      } catch (_) {}
      await _loadSourceFromPath(newPath, updatedSession, boosted: false);
      newPath = null;

      try {
        if (await boostFile.exists()) await boostFile.delete();
      } catch (_) {}

      try {
        if (oldPath != updatedSession.audioPath) {
          final f = File(oldPath);
          if (await f.exists()) await f.delete();
        }
      } catch (_) {}

      if (mounted) {
        setState(() => _savingAmplified = false);
        messenger.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Amplified audio saved as this recording.',
            'Audio amplifié enregistré comme cet enregistrement.',
          )),
        ));
      }
    } catch (e) {
      if (!committed && copiedBoost && newPath != null) {
        try {
          final f = File(newPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      if (mounted) {
        setState(() => _savingAmplified = false);
        messenger.showSnackBar(SnackBar(
          content: Text(tr(
            widget.preferences,
            'Could not save amplified audio: $e',
            'Impossible d’enregistrer l’audio amplifié : $e',
          )),
        ));
      }

      if (committed) {
        try {
          await _loadAudio();
        } catch (_) {}
      }
    }
  }

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours.toString().padLeft(2, '0')}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  Future<void> _seekRelative(int seconds) async {
    final duration = _player.duration ?? Duration.zero;
    if (duration.inMilliseconds <= 0) return;
    final target = _player.position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > duration ? duration : target);
    await _player.seek(clamped);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateFormat(
      'dd MMM yyyy, HH:mm',
      widget.preferences.isFrench ? 'fr' : 'en',
    ).format(_currentProject.createdAt);
    final showSaveButton =
        _volumeBoost > 1.0 && _boostedPath != null && !_isProtected;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(widget.preferences, 'Recording', 'Enregistrement')),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: tr(widget.preferences, 'More actions', 'Plus d’actions'),
            onSelected: (action) async {
              final messenger = ScaffoldMessenger.of(context);
              if (action == 'create_project') widget.onCreateProject();
              if (action == 'share') await widget.onShare();
              if (action == 'rename') await _renameRecording();
              if (action == 'trim' && widget.onTrim != null) {
                try {
                  await _player.stop();
                } catch (_) {}
                await widget.onTrim!();
              }
              if (action == 'pin' && widget.onTogglePin != null) {
                await widget.onTogglePin!();
                if (mounted) setState(() => _requiresPin = !_requiresPin);
              }
              if (action == 'encryption') {
                try {
                  await _player.stop();
                } catch (_) {}
                await _deleteBoostedFile();
                await widget.onToggleEncryption();
              }
              if (action == 'visibility') {
                try {
                  final location = await widget.onToggleVisibility();
                  if (mounted) {
                    setState(() => _publicCopyLocation = location);
                  }
                } catch (error) {
                  if (!mounted || !messenger.mounted) return;
                  messenger.showSnackBar(SnackBar(
                    content:
                        Text('Could not update recording visibility: $error'),
                  ));
                }
              }
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'pin',
                child: Text(tr(
                  widget.preferences,
                  _requiresPin ? 'Remove PIN lock' : 'Require PIN to open',
                  _requiresPin
                      ? 'Retirer le verrouillage PIN'
                      : 'Exiger un PIN pour ouvrir',
                )),
              ),
              PopupMenuItem<String>(
                value: 'share',
                child: Text(
                    tr(widget.preferences, 'Share audio', 'Partager l’audio')),
              ),
              PopupMenuItem<String>(
                value: 'rename',
                child: Text(
                    tr(widget.preferences, 'Rename recording', 'Renommer')),
              ),
              if (widget.onTrim != null)
                PopupMenuItem<String>(
                  value: 'trim',
                  enabled: !_isProtected,
                  child: Text(tr(widget.preferences, 'Trim audio',
                      'Rogner l’audio')),
                ),
              PopupMenuItem<String>(
                value: 'encryption',
                child: Text(tr(
                  widget.preferences,
                  _isProtected
                      ? 'Unlock audio'
                      : 'Lock audio with a password',
                  _isProtected
                      ? 'Déverrouiller l’audio'
                      : 'Verrouiller l’audio avec un mot de passe',
                )),
              ),
              PopupMenuItem<String>(
                value: 'visibility',
                child: Text(tr(
                  widget.preferences,
                  _publicCopyLocation == null
                      ? 'Make recording public'
                      : 'Make recording private',
                  _publicCopyLocation == null
                      ? 'Rendre l’enregistrement public'
                      : 'Rendre l’enregistrement privé',
                )),
              ),
              PopupMenuItem<String>(
                value: 'create_project',
                child: Text(tr(
                    widget.preferences, 'Create project', 'Créer un projet')),
              ),
            ],
          ),
          if (showSaveButton)
            _savingAmplified
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : IconButton(
                    tooltip: tr(
                      widget.preferences,
                      'Save amplified audio as this recording',
                      'Enregistrer l’audio amplifié comme cet enregistrement',
                    ),
                    onPressed: _saveAmplifiedAsRecording,
                    icon: const Icon(Icons.save_alt_rounded),
                  ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snapshot) {
                    final playing = snapshot.data?.playing ?? false;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      height: 190,
                      decoration: BoxDecoration(
                        color: _isProtected
                            ? theme.colorScheme.tertiaryContainer
                                .withValues(alpha: 0.7)
                            : (playing
                                ? theme.colorScheme.primaryContainer
                                : theme.colorScheme.primaryContainer
                                    .withValues(alpha: 0.7)),
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: playing && !_isProtected
                            ? <BoxShadow>[
                                BoxShadow(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.28),
                                  blurRadius: 26,
                                  spreadRadius: 3,
                                ),
                              ]
                            : null,
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          Icon(
                            _isProtected
                                ? Icons.lock_rounded
                                : Icons.mic_rounded,
                            size: 74,
                            color: _isProtected
                                ? theme.colorScheme.onTertiaryContainer
                                : theme.colorScheme.onPrimaryContainer,
                          ),
                          if (playing && !_isProtected)
                            Positioned(
                              bottom: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(Icons.graphic_eq_rounded,
                                        size: 12,
                                        color: theme.colorScheme.onPrimary),
                                    const SizedBox(width: 4),
                                    Text(
                                      tr(widget.preferences, 'Playing',
                                          'Lecture'),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.5,
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (_volumeBoost > 1.0 && !_isProtected)
                            Positioned(
                              top: 12,
                              right: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(Icons.volume_up_rounded,
                                        size: 12,
                                        color: theme.colorScheme.onPrimary),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${(_volumeBoost * 100).round()}%',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  _title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  '$date  ·  ${tr(widget.preferences, 'Standalone recording', 'Enregistrement autonome')}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 36),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_isProtected)
                  _buildLockedPanel(theme)
                else if (_error != null)
                  _buildErrorPanel(theme)
                else
                  _buildPlayerPanel(theme),
                const SizedBox(height: 36),
                if (!_isProtected)
                  FilledButton.icon(
                    onPressed: widget.onResume,
                    icon: const Icon(Icons.mic_rounded),
                    label: Text(tr(widget.preferences, 'Resume recording',
                        'Reprendre l’enregistrement')),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockedPanel(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: <Widget>[
          Icon(Icons.enhanced_encryption_rounded,
              size: 40, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(height: 12),
          Text(
            tr(widget.preferences, 'Password-protected',
                'Protégé par un mot de passe'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              widget.preferences,
              'This recording is encrypted on this device. Enter your password to listen.',
              'Cet enregistrement est chiffré sur cet appareil. Saisissez votre mot de passe pour l’écouter.',
            ),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () async {
              try {
                await widget.onToggleEncryption();
              } catch (_) {}
            },
            icon: const Icon(Icons.lock_open_rounded),
            label: Text(tr(widget.preferences, 'Unlock audio',
                'Déverrouiller l’audio')),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorPanel(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: <Widget>[
          Icon(Icons.error_outline_rounded,
              size: 40, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () {
              setState(() => _error = null);
              _loadAudio();
            },
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr(widget.preferences, 'Retry', 'Réessayer')),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerPanel(ThemeData theme) {
    return Column(
      children: <Widget>[
        StreamBuilder<Duration>(
          stream: _player.positionStream,
          builder: (context, snapshot) {
            final position = snapshot.data ?? Duration.zero;
            final duration = _player.duration ?? Duration.zero;
            final max = duration.inMilliseconds.toDouble();
            return Column(
              children: <Widget>[
                Slider(
                  value: max <= 0
                      ? 0.0
                      : position.inMilliseconds
                          .toDouble()
                          .clamp(0.0, max)
                          .toDouble(),
                  max: max <= 0 ? 1.0 : max,
                  onChanged: max <= 0
                      ? null
                      : (value) => _player.seek(
                            Duration(milliseconds: value.round()),
                          ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(_format(position),
                          style: theme.textTheme.labelMedium),
                      Text(_format(duration),
                          style: theme.textTheme.labelMedium),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        StreamBuilder<PlayerState>(
          stream: _player.playerStateStream,
          builder: (context, snapshot) {
            final playing = snapshot.data?.playing ?? false;
            final duration = _player.duration ?? Duration.zero;
            final canSeek = duration.inMilliseconds > 0;
            return Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: <Widget>[
                IconButton(
                  tooltip:
                      tr(widget.preferences, 'Restart', 'Recommencer'),
                  onPressed:
                      _loading ? null : () => _player.seek(Duration.zero),
                  icon: const Icon(Icons.replay_rounded),
                  iconSize: 24,
                ),
                IconButton(
                  tooltip: '-10s',
                  onPressed: _loading || !canSeek
                      ? null
                      : () => _seekRelative(-10),
                  icon: const Icon(Icons.replay_10_rounded),
                  iconSize: 26,
                ),
                SizedBox(
                  width: 76,
                  height: 76,
                  child: IconButton.filled(
                    onPressed: _loading
                        ? null
                        : () {
                            if (playing) {
                              _player.pause();
                            } else {
                              unawaited(_player.play());
                            }
                          },
                    iconSize: 36,
                    icon: Icon(
                      playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '+10s',
                  onPressed: _loading || !canSeek
                      ? null
                      : () => _seekRelative(10),
                  icon: const Icon(Icons.forward_10_rounded),
                  iconSize: 26,
                ),
                if (_boostProcessing)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr(widget.preferences, 'Amplifying…',
                              'Amplification…'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  PopupMenuButton<double>(
                    tooltip: tr(widget.preferences, 'Amplify volume',
                        'Amplifier le volume'),
                    onSelected: _applyBoost,
                    itemBuilder: (_) => <PopupMenuEntry<double>>[
                      for (final level in <double>[
                        1.0,
                        1.25,
                        1.5,
                        1.75,
                        2.0
                      ])
                        PopupMenuItem<double>(
                          value: level,
                          child: Row(
                            children: <Widget>[
                              if (level == _volumeBoost)
                                const Icon(Icons.check_rounded, size: 18)
                              else
                                const SizedBox(width: 18),
                              const SizedBox(width: 8),
                              Text(level == 1.0
                                  ? tr(widget.preferences,
                                      'Normal (100%)', 'Normal (100%)')
                                  : '${(level * 100).round()}%'),
                            ],
                          ),
                        ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: _volumeBoost > 1.0
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            _volumeBoost > 1.0
                                ? Icons.volume_up_rounded
                                : Icons.volume_down_rounded,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${(_volumeBoost * 100).round()}%',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                PopupMenuButton<double>(
                  tooltip: tr(widget.preferences, 'Playback speed',
                      'Vitesse de lecture'),
                  onSelected: (value) async {
                    setState(() => _speed = value);
                    try {
                      await _player.setSpeed(value);
                    } catch (_) {}
                  },
                  itemBuilder: (_) => <PopupMenuEntry<double>>[
                    for (final s in <double>[
                      0.5,
                      0.75,
                      1.0,
                      1.25,
                      1.5,
                      2.0
                    ])
                      PopupMenuItem<double>(
                        value: s,
                        child: Row(
                          children: <Widget>[
                            if (s == _speed)
                              const Icon(Icons.check_rounded, size: 18)
                            else
                              const SizedBox(width: 18),
                            const SizedBox(width: 8),
                            Text('$s×'),
                          ],
                        ),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$_speed×',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        Text(
          tr(
            widget.preferences,
            'Amplify processes this recording through a limiter so quiet audio gets louder without cracking. The saved file keeps the same format and quality tier as the recording. Use the save icon in the top bar to keep the amplified version.',
            'L’amplification traite cet enregistrement via un limiteur : l’audio discret devient plus fort sans grésiller. Le fichier enregistré garde le format et la qualité de l’enregistrement. Utilisez l’icône d’enregistrement en haut pour conserver la version amplifiée.',
          ),
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _renameRecording() async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameRecordingDialog(
        title: _title,
        preferences: widget.preferences,
      ),
    );
    if (title == null || title.trim().isEmpty || title.trim() == _title) {
      return;
    }
    final renamed = await widget.onRename(title.trim());
    if (renamed && mounted) {
      setState(() {
        _title = title.trim();
        _currentProject = _currentProject.copyWith(title: title.trim());
      });
    }
  }
}

class _RenameRecordingDialog extends StatefulWidget {
  const _RenameRecordingDialog({
    required this.title,
    required this.preferences,
  });

  final String title;
  final AppPreferences preferences;

  @override
  State<_RenameRecordingDialog> createState() => _RenameRecordingDialogState();
}

class _RenameRecordingDialogState extends State<_RenameRecordingDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr(widget.preferences, 'Rename recording',
          'Renommer l’enregistrement')),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 80,
        decoration: InputDecoration(
          labelText: tr(widget.preferences, 'Recording title',
              'Titre de l’enregistrement'),
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(tr(widget.preferences, 'Save', 'Enregistrer')),
        ),
      ],
    );
  }
}