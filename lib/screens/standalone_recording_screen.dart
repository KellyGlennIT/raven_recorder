import 'dart:io';

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
    required this.onOpenDetails,
    required this.onCreateProject,
    required this.onShare,
    required this.onRename,
    required this.onToggleEncryption,
    required this.onToggleVisibility,
    this.onTogglePin,
    this.autoPlay = false,
    super.key,
  });

  final RavenProject project;
  final AppPreferences preferences;
  final VoidCallback onResume;
  final VoidCallback onOpenDetails;
  final VoidCallback onCreateProject;
  final Future<void> Function() onShare;
  final Future<bool> Function(String title) onRename;
  final Future<void> Function() onToggleEncryption;
  final Future<String?> Function() onToggleVisibility;
  final Future<void> Function()? onTogglePin;
  final bool autoPlay;

  @override
  State<StandaloneRecordingScreen> createState() =>
      _StandaloneRecordingScreenState();
}

class _StandaloneRecordingScreenState extends State<StandaloneRecordingScreen> {
  AudioPlayer get _player => PlaybackService().player;
  late String _title;
  late bool _requiresPin;
  String? _publicCopyLocation;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _title = widget.project.title;
    _requiresPin = widget.project.requiresAppPin;
    _publicCopyLocation = widget.project.publicFolderLocation ??
        widget.project.publicCopyLocation;
    _loadAudio();
  }

  @override
  void dispose() {
    // Shared global player lives across screens and processes background playback.
    super.dispose();
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

  Future<void> _loadAudio() async {
    final masterPath = widget.project.masterAudioPath;
    final masterExists = masterPath != null && await File(masterPath).exists();
    if (widget.project.sessions.isEmpty && !masterExists) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = tr(widget.preferences, 'This standalone recording has no audio yet.',
              'Cet enregistrement ne contient pas encore d’audio.');
        });
      }
      return;
    }
    try {
      Uri? artUri;
      try {
        artUri = await _artUri().timeout(const Duration(milliseconds: 400),
            onTimeout: () => null);
      } catch (_) {}
      final mediaItem = MediaItem(
        id: widget.project.id,
        title: _title,
        album: 'RAVEN',
        duration: widget.project.sessions.isNotEmpty
            ? Duration(milliseconds: widget.project.sessions.first.durationMs)
            : null,
        artUri: artUri,
      );

      final master = widget.project.masterAudioPath;
      if (master != null && await File(master).exists()) {
        await _player.setAudioSource(
          AudioSource.uri(Uri.file(master), tag: mediaItem),
          initialPosition: Duration.zero,
        );
      } else {
        final sources = <AudioSource>[];
        for (final session in widget.project.sessions) {
          final file = File(session.audioPath);
          if (!await file.exists()) {
            throw FileSystemException(
                'A recording segment is missing.', file.path);
          }
          sources.add(AudioSource.uri(Uri.file(file.path), tag: mediaItem));
        }
        if (sources.isEmpty) {
          throw StateError('This standalone recording has no audio yet.');
        }
        await _player.setAudioSource(
          sources.length == 1
              ? sources.single
              : ConcatenatingAudioSource(
                  children: sources,
                  useLazyPreparation: true,
                ),
          initialPosition: Duration.zero,
        );
      }
      if (widget.autoPlay && mounted) {
        await _player.play();
      }
    } catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _format(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours.toString().padLeft(2, '0')}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = DateFormat(
      'dd MMM yyyy, HH:mm',
      widget.preferences.isFrench ? 'fr' : 'en',
    ).format(widget.project.createdAt);
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
              if (action == 'pin' && widget.onTogglePin != null) {
                await widget.onTogglePin!();
                if (mounted) setState(() => _requiresPin = !_requiresPin);
              }
              if (action == 'encryption') {
                await _player.pause();
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
              PopupMenuItem<String>(
                value: 'encryption',
                child: Text(tr(
                  widget.preferences,
                  widget.project.isAudioProtected
                      ? 'Unlock audio'
                      : 'Lock audio with a password',
                  widget.project.isAudioProtected
                      ? 'Déverrouiller l’audio'
                      : 'Verrouiller l’audio avec un mot de passe',
                )),
              ),
              PopupMenuItem<String>(
                value: 'visibility',
                child: Text(tr(
                  widget.preferences,
                  _publicCopyLocation == null
                      ? 'Make project public'
                      : 'Make project private',
                  _publicCopyLocation == null
                      ? 'Rendre le projet public'
                      : 'Rendre le projet privé',
                )),
              ),
              PopupMenuItem<String>(
                value: 'create_project',
                child: Text(tr(
                    widget.preferences, 'Create project', 'Créer un projet')),
              ),
            ],
          ),
          IconButton(
            tooltip: tr(widget.preferences, 'More details and files',
                'Plus de détails et de fichiers'),
            onPressed: widget.onOpenDetails,
            icon: const Icon(Icons.tune_rounded),
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
                Container(
                  height: 190,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Icon(
                    Icons.mic_rounded,
                    size: 74,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
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
                else if (_error != null)
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  )
                else ...<Widget>[
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
                                ? 0
                                : position.inMilliseconds
                                    .toDouble()
                                    .clamp(0, max),
                            max: max <= 0 ? 1 : max,
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
                                Text(_format(position)),
                                Text(_format(duration)),
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
                      return Center(
                        child: IconButton.filled(
                          onPressed: _loading
                              ? null
                              : () =>
                                  playing ? _player.pause() : _player.play(),
                          iconSize: 36,
                          style: IconButton.styleFrom(
                            fixedSize: const Size(76, 76),
                          ),
                          icon: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 36),
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
    if (renamed && mounted) setState(() => _title = title.trim());
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
      title: Text(tr(
          widget.preferences, 'Rename recording', 'Renommer l’enregistrement')),
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
