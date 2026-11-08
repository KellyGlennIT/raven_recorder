import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:intl/intl.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';

class StandaloneRecordingScreen extends StatefulWidget {
  const StandaloneRecordingScreen({
    required this.project,
    required this.preferences,
    required this.onResume,
    required this.onOpenDetails,
    super.key,
  });

  final RavenProject project;
  final AppPreferences preferences;
  final VoidCallback onResume;
  final VoidCallback onOpenDetails;

  @override
  State<StandaloneRecordingScreen> createState() =>
      _StandaloneRecordingScreenState();
}

class _StandaloneRecordingScreenState extends State<StandaloneRecordingScreen> {
  final AudioPlayer _player = AudioPlayer();
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAudio();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadAudio() async {
    try {
      final master = widget.project.masterAudioPath;
      if (master != null && await File(master).exists()) {
        await _player.setAudioSource(AudioSource.uri(Uri.file(master)));
      } else {
        final sources = <AudioSource>[];
        for (final session in widget.project.sessions) {
          final file = File(session.audioPath);
          if (!await file.exists()) {
            throw FileSystemException(
                'A recording segment is missing.', file.path);
          }
          sources.add(AudioSource.uri(Uri.file(file.path)));
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
        );
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
                  widget.project.title,
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
}
