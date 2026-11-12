import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../services/audio_trim_service.dart';
import '../services/playback_service.dart';

class TrimEditorResult {
  const TrimEditorResult({
    required this.file,
    required this.durationMs,
    required this.replacedOriginal,
  });

  final File file;
  final int durationMs;
  final bool replacedOriginal;
}

class TrimEditor extends StatefulWidget {
  const TrimEditor({
    required this.source,
    required this.format,
    required this.durationMs,
    required this.bitRate,
    required this.sampleRate,
    required this.title,
    required this.isFrench,
    this.isStandalone = true,
    super.key,
  });

  final File source;
  final String format;
  final int durationMs;
  final int bitRate;
  final int sampleRate;
  final String title;
  final bool isFrench;
  final bool isStandalone;

  @override
  State<TrimEditor> createState() => _TrimEditorState();
}

class _TrimEditorState extends State<TrimEditor> {
  AudioPlayer get _player => PlaybackService().player;

  double _selStart = 0.0;
  double _selEnd = 1.0;
  List<(double, double)> _cuts = <(double, double)>[];

  bool _processing = false;
  double? _progress;
  String _stage = '';

  bool _previewing = false;
  StreamSubscription<Duration>? _posSub;
  Duration _previewPos = Duration.zero;

  String label(String en, String fr) => widget.isFrench ? fr : en;

  @override
  void initState() {
    super.initState();
    try {
      _player.stop();
    } catch (_) {}
  }

  @override
  void dispose() {
    _posSub?.cancel();
    try {
      _player.stop();
    } catch (_) {}
    super.dispose();
  }

  int get _durationMs => widget.durationMs > 0 ? widget.durationMs : 1;
  int get _startMs => (_selStart * _durationMs).round();
  int get _endMs => (_selEnd * _durationMs).round();

  bool get _hasCuts => _cuts.isNotEmpty;

  /// Formats a duration as `MM:SS.S` (or `H:MM:SS.S` for >1 hr).
  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = ((ms.abs() % 1000) / 100).floor();
    return h > 0 ? '$h:$m:$s.$tenths' : '$m:$s.$tenths';
  }

  /// Parses user input: accepts `MM:SS.S`, `SS.S`, `H:MM:SS.S`, or bare
  /// milliseconds. Returns null on parse failure.
  int? _parseTime(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    final parts = t.split(':');
    try {
      if (parts.length == 1) {
        final v = double.parse(parts[0]);
        return (v * 1000).round();
      } else if (parts.length == 2) {
        final m = int.parse(parts[0]);
        final s = double.parse(parts[1]);
        return ((m * 60 + s) * 1000).round();
      } else if (parts.length == 3) {
        final h = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final s = double.parse(parts[2]);
        return ((h * 3600 + m * 60 + s) * 1000).round();
      }
    } catch (_) {}
    return null;
  }

  List<TrimRegion> get _keepRegions {
    var spans = <(double, double)>[(0.0, 1.0)];
    for (final cut in _cuts) {
      final next = <(double, double)>[];
      for (final span in spans) {
        if (cut.$2 <= span.$1 || cut.$1 >= span.$2) {
          next.add(span);
          continue;
        }
        if (cut.$1 > span.$1) next.add((span.$1, cut.$1));
        if (cut.$2 < span.$2) next.add((cut.$2, span.$2));
      }
      spans = next;
    }
    final regions = <TrimRegion>[];
    for (final span in spans) {
      final s = (span.$1 * _durationMs).round();
      final e = (span.$2 * _durationMs).round();
      if (e > s) regions.add(TrimRegion(startMs: s, endMs: e));
    }
    return regions;
  }

  int get _keptMs =>
      _keepRegions.fold<int>(0, (sum, r) => sum + r.durationMs);

  bool get _isUnchanged {
    final regions = _keepRegions;
    return regions.length == 1 &&
        regions.first.startMs <= 0 &&
        regions.first.endMs >= _durationMs;
  }

  Future<void> _playSelection() async {
    if (_processing || _endMs <= _startMs) return;
    try {
      _posSub?.cancel();
      await _player.stop();
      final tag = MediaItem(
        id: 'trim-preview-${widget.source.path.hashCode}',
        title: '${widget.title} · ${label('Preview', 'Préécoute')}',
        album: 'RAVEN',
      );
      await _player.setAudioSource(
        AudioSource.uri(Uri.file(widget.source.path), tag: tag),
      );
      await _player.seek(Duration(milliseconds: _startMs));
      unawaited(_player.play());
      if (mounted) {
        setState(() {
          _previewing = true;
          _previewPos = Duration(milliseconds: _startMs);
        });
      }
      _posSub = _player.positionStream.listen((pos) {
        final ms = pos.inMilliseconds;
        if (ms >= _endMs || ms < _startMs - 500) {
          _player.stop();
          _posSub?.cancel();
          if (mounted) {
            setState(() {
              _previewing = false;
              _previewPos = Duration.zero;
            });
          }
          return;
        }
        if (mounted) setState(() => _previewPos = pos);
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '${label('Preview failed', 'Échec de la préécoute')}: $error'),
      ));
    }
  }

  void _stopPreview() {
    _posSub?.cancel();
    _player.stop();
    if (mounted) {
      setState(() {
        _previewing = false;
        _previewPos = Duration.zero;
      });
    }
  }

  Future<void> _editTime({required bool isStart}) async {
    final currentMs = isStart ? _startMs : _endMs;
    final controller = TextEditingController(text: _fmt(currentMs));
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          isStart
              ? label('Set start time', 'Définir le début')
              : label('Set end time', 'Définir la fin'),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label(
                'Enter a time as MM:SS.S, SS.S, or HH:MM:SS.S.',
                'Saisissez un temps au format MM:SS.S, SS.S, ou HH:MM:SS.S.',
              ),
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: label('Time', 'Temps'),
                hintText: '01:23.4',
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(label('Cancel', 'Annuler')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(label('Set', 'Définir')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    final ms = _parseTime(result);
    if (ms == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(label(
            'Could not read that time. Try 01:23.4.',
            'Impossible de lire ce temps. Essayez 01:23.4.',
          )),
        ));
      }
      return;
    }
    final clamped = ms.clamp(0, _durationMs);
    setState(() {
      if (isStart) {
        _selStart = (clamped / _durationMs)
            .clamp(0.0, (_selEnd - 0.001).clamp(0.0, 1.0));
      } else {
        _selEnd = (clamped / _durationMs)
            .clamp((_selStart + 0.001).clamp(0.0, 1.0), 1.0);
      }
    });
  }

  void _nudge({required bool isStart, required int deltaMs}) {
    setState(() {
      if (isStart) {
        final newMs = (_startMs + deltaMs).clamp(0, _endMs - 100);
        _selStart = newMs / _durationMs;
      } else {
        final newMs = (_endMs + deltaMs).clamp(_startMs + 100, _durationMs);
        _selEnd = newMs / _durationMs;
      }
    });
  }

  void _applyCutSelection() {
    final spanMs = _endMs - _startMs;
    if (spanMs >= _durationMs) return;
    if (spanMs < 100) {
      _toast(label(
        'Selection is too short to cut. Drag the handles wider.',
        'La sélection est trop courte. Élargissez les poignées.',
      ));
      return;
    }
    setState(() => _cuts = [..._cuts, (_selStart, _selEnd)]);
  }

  void _applyKeepOnlySelection() {
    if (_selStart <= 0.001 && _selEnd >= 0.999) return;
    if (_endMs - _startMs < 100) {
      _toast(label(
        'Selection is too short to keep. Drag the handles wider.',
        'La sélection est trop courte. Élargissez les poignées.',
      ));
      return;
    }
    final before = _selStart > 0.001
        ? <(double, double)>[(0.0, _selStart)]
        : <(double, double)>[];
    final after = _selEnd < 0.999
        ? <(double, double)>[(_selEnd, 1.0)]
        : <(double, double)>[];
    setState(() => _cuts = [...before, ...after]);
  }

  void _undoLastCut() {
    if (_cuts.isEmpty) return;
    setState(() => _cuts = _cuts.sublist(0, _cuts.length - 1));
  }

  void _resetAll() {
    setState(() {
      _cuts = <(double, double)>[];
      _selStart = 0.0;
      _selEnd = 1.0;
    });
  }

  String _outputBaseName() {
    var name = widget.source.uri.pathSegments.last;
    if (name.contains('.')) name = name.substring(0, name.lastIndexOf('.'));
    name = name.replaceAll(RegExp(r'-trimmed-\d+$'), '');
    if (name.trim().isEmpty) name = 'recording';
    return name;
  }

  String _sanitizeName(String value) => value
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), '_');

  String _extensionFor(String format) => switch (format.toLowerCase()) {
        'wav' => 'wav',
        'flac' => 'flac',
        'mp3' => 'mp3',
        _ => 'm4a',
      };

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_processing) return;

    final regions = _keepRegions;
    if (regions.isEmpty) {
      _toast(label(
        'Nothing to keep — every region is cut.',
        'Rien à garder — toutes les régions sont coupées.',
      ));
      return;
    }
    if (_isUnchanged) {
      _toast(label(
        'Make a cut or narrow the selection first.',
        'Faites d’abord une coupe ou réduisez la sélection.',
      ));
      return;
    }

    final choice = await showDialog<_TrimSaveChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.content_cut_rounded),
        title: Text(label('Save trimmed audio', 'Enregistrer l’audio rogné')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label(
                'Keep ${_fmt(_keptMs)} of ${_fmt(_durationMs)}.',
                'Garder ${_fmt(_keptMs)} sur ${_fmt(_durationMs)}.',
              ),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            _ChoiceOption(
              icon: Icons.library_add_outlined,
              title: widget.isStandalone
                  ? label('Save as new recording',
                      'Enregistrer comme nouvel enregistrement')
                  : label('Save as new take', 'Enregistrer comme nouvelle prise'),
              subtitle: widget.isStandalone
                  ? label(
                      'The original stays untouched. The trimmed copy becomes a new recording in your library.',
                      'L’original reste intact. La copie rognée devient un nouvel enregistrement dans votre bibliothèque.')
                  : label(
                      'The original take stays untouched. The trimmed copy is added next to it in this project.',
                      'La prise d’origine reste intacte. La copie rognée est ajoutée à côté dans ce projet.'),
            ),
            const SizedBox(height: 10),
            _ChoiceOption(
              icon: Icons.swap_horiz_rounded,
              title: label('Replace original', 'Remplacer l’original'),
              subtitle: label(
                'The original audio is removed after the trimmed copy is saved.',
                'L’audio d’origine est supprimé après l’enregistrement de la copie rognée.',
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(label('Cancel', 'Annuler')),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _TrimSaveChoice.saveAsNew),
            child: Text(widget.isStandalone
                ? label('New recording', 'Nouvel enregistrement')
                : label('New take', 'Nouvelle prise')),
          ),
          FilledButton.icon(
            onPressed: () =>
                Navigator.pop(dialogContext, _TrimSaveChoice.replace),
            icon: const Icon(Icons.swap_horiz_rounded, size: 18),
            label: Text(label('Replace', 'Remplacer')),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    setState(() {
      _processing = true;
      _progress = 0.0;
      _stage = label('Preparing…', 'Préparation…');
    });

    final messenger = ScaffoldMessenger.of(context);
    try {
      final ext = _extensionFor(widget.format);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final parent = widget.source.parent;
      final base = _sanitizeName(_outputBaseName());
      final targetPath = '${parent.path}/$base-trimmed-$stamp.$ext';

      final result = await AudioTrimService.instance.trim(
        source: widget.source,
        outputPath: targetPath,
        format: widget.format,
        totalDurationMs: _durationMs,
        regions: regions,
        bitRate: widget.bitRate,
        sampleRate: widget.sampleRate,
        onProgress: (p, stage) {
          if (mounted) {
            setState(() {
              _progress = p;
              _stage = stage;
            });
          }
        },
      );

      if (!mounted) return;
      Navigator.of(context).pop(TrimEditorResult(
        file: result.outputFile,
        durationMs: result.durationMs,
        replacedOriginal: choice == _TrimSaveChoice.replace,
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _progress = null;
        _stage = '';
      });
      messenger.showSnackBar(SnackBar(
        content: Text(
            '${label('Could not trim recording', 'Impossible de rogner')}: $error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectionMs = _endMs - _startMs;
    final hasEdits = _hasCuts || _selStart > 0.001 || _selEnd < 0.999;

    return PopScope(
      canPop: !_processing,
      child: Scaffold(
        appBar: AppBar(
          leading: _processing
              ? const Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
          title: Text(label('Trim recording', 'Rogner l’enregistrement')),
          actions: <Widget>[
            IconButton(
              tooltip: label('Reset all edits', 'Tout réinitialiser'),
              onPressed: _processing || !hasEdits ? null : _resetAll,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // Title + pills
                      Text(
                        widget.title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          _Pill(
                            icon: Icons.audiotrack_rounded,
                            text: widget.format.toUpperCase(),
                          ),
                          _Pill(
                            icon: Icons.timer_outlined,
                            text: _fmt(_durationMs),
                          ),
                          _Pill(
                            icon: Icons.content_cut_rounded,
                            text: '${label('Keep', 'Garder')} ${_fmt(_keptMs)}',
                            highlight: hasEdits,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),

                      // Timeline
                      _TimelineBar(
                        durationMs: _durationMs,
                        selStart: _selStart,
                        selEnd: _selEnd,
                        cuts: _cuts,
                        previewPos: _previewing
                            ? _previewPos.inMilliseconds / _durationMs
                            : null,
                        enabled: !_processing,
                        fmt: _fmt,
                        onChanged: (start, end) => setState(() {
                          _selStart = start;
                          _selEnd = end;
                        }),
                      ),
                      const SizedBox(height: 12),

                      // Selection card with editable times
                      _SelectionCard(
                        startMs: _startMs,
                        endMs: _endMs,
                        durationMs: selectionMs,
                        fmt: _fmt,
                        enabled: !_processing,
                        onEditStart: () => _editTime(isStart: true),
                        onEditEnd: () => _editTime(isStart: false),
                        onNudgeStart: (delta) =>
                            _nudge(isStart: true, deltaMs: delta),
                        onNudgeEnd: (delta) =>
                            _nudge(isStart: false, deltaMs: delta),
                        labels: (
                          start: label('Start', 'Début'),
                          end: label('End', 'Fin'),
                          duration: label('Duration', 'Durée'),
                          nudge: label('Nudge', 'Ajuster'),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Keep strip
                      _KeepStrip(
                        keepRegions: _keepRegions,
                        durationMs: _durationMs,
                        isFrench: widget.isFrench,
                      ),
                      const SizedBox(height: 16),

                      // Action buttons
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: <Widget>[
                          OutlinedButton.icon(
                            onPressed: _processing || selectionMs >= _durationMs
                                ? null
                                : _applyCutSelection,
                            icon: const Icon(Icons.content_cut_rounded,
                                size: 18),
                            label: Text(label('Cut selection', 'Couper')),
                          ),
                          OutlinedButton.icon(
                            onPressed: _processing ||
                                    (_selStart <= 0.001 && _selEnd >= 0.999)
                                ? null
                                : _applyKeepOnlySelection,
                            icon: const Icon(Icons.crop_rounded, size: 18),
                            label:
                                Text(label('Keep only', 'Garder seulement')),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                _processing || _cuts.isEmpty ? null : _undoLastCut,
                            icon: const Icon(Icons.undo_rounded, size: 18),
                            label:
                                Text(label('Undo cut', 'Annuler la coupe')),
                          ),
                        ],
                      ),

                      // Processing progress
                      if (_processing) ...<Widget>[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      value: _progress,
                                      color: scheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      '${_stage.isEmpty ? label('Trimming…', 'Rognage…') : _stage} · ${((_progress ?? 0) * 100).round()}%',
                                      style: theme.textTheme.labelMedium
                                          ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (!_processing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _previewing ? _stopPreview : _playSelection,
                          icon: Icon(_previewing
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded),
                          label: Text(_previewing
                              ? label('Stop', 'Arrêter')
                              : label('Preview', 'Préécoute')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: hasEdits ? _save : null,
                          icon: const Icon(Icons.save_rounded),
                          label: Text(label('Save trimmed audio',
                              'Enregistrer le rognage')),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    this.highlight = false,
  });

  final IconData icon;
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            icon,
            size: 12,
            color:
                highlight ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: highlight
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChoiceOption extends StatelessWidget {
  const _ChoiceOption({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionCard extends StatelessWidget {
  const _SelectionCard({
    required this.startMs,
    required this.endMs,
    required this.durationMs,
    required this.fmt,
    required this.enabled,
    required this.onEditStart,
    required this.onEditEnd,
    required this.onNudgeStart,
    required this.onNudgeEnd,
    required this.labels,
  });

  final int startMs;
  final int endMs;
  final int durationMs;
  final String Function(int) fmt;
  final bool enabled;
  final VoidCallback onEditStart;
  final VoidCallback onEditEnd;
  final void Function(int deltaMs) onNudgeStart;
  final void Function(int deltaMs) onNudgeEnd;
  final ({String start, String end, String duration, String nudge}) labels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: _TimeField(
              label: labels.start,
              value: fmt(startMs),
              enabled: enabled,
              onEdit: onEditStart,
              onNudge: onNudgeStart,
              nudgeLabel: labels.nudge,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _TimeField(
              label: labels.end,
              value: fmt(endMs),
              enabled: enabled,
              onEdit: onEditEnd,
              onNudge: onNudgeEnd,
              nudgeLabel: labels.nudge,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    labels.duration.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    fmt(durationMs),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onEdit,
    required this.onNudge,
    required this.nudgeLabel,
  });

  final String label;
  final String value;
  final bool enabled;
  final VoidCallback onEdit;
  final void Function(int deltaMs) onNudge;
  final String nudgeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        InkWell(
          onTap: enabled ? onEdit : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Flexible(
                  child: Text(
                    value,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Icon(Icons.edit_outlined,
                    size: 14, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Tooltip(
          message: nudgeLabel,
          child: Row(
            children: <Widget>[
              _NudgeButton(
                text: '−5s',
                onTap: enabled ? () => onNudge(-5000) : null,
              ),
              const SizedBox(width: 4),
              _NudgeButton(
                text: '−1s',
                onTap: enabled ? () => onNudge(-1000) : null,
              ),
              const SizedBox(width: 4),
              _NudgeButton(
                text: '+1s',
                onTap: enabled ? () => onNudge(1000) : null,
              ),
              const SizedBox(width: 4),
              _NudgeButton(
                text: '+5s',
                onTap: enabled ? () => onNudge(5000) : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({required this.text, required this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: onTap == null
                      ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                      : scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _TrimSaveChoice { replace, saveAsNew }

class _TimelineBar extends StatefulWidget {
  const _TimelineBar({
    required this.durationMs,
    required this.selStart,
    required this.selEnd,
    required this.cuts,
    required this.previewPos,
    required this.enabled,
    required this.fmt,
    required this.onChanged,
  });

  final int durationMs;
  final double selStart;
  final double selEnd;
  final List<(double, double)> cuts;
  final double? previewPos;
  final bool enabled;
  final String Function(int) fmt;
  final void Function(double start, double end) onChanged;

  @override
  State<_TimelineBar> createState() => _TimelineBarState();
}

class _TimelineBarState extends State<_TimelineBar> {
  int _activeHandle = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final selStart = widget.selStart;
    final selEnd = widget.selEnd;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      const handleHalf = 14.0;
      const labelWidth = 70.0;

      double fracOf(double x) =>
          ((x - handleHalf) / (width - 2 * handleHalf)).clamp(0.0, 1.0)
              .toDouble();

      double xOf(double frac) =>
          handleHalf + frac * (width - 2 * handleHalf);

      void move(double f) {
        if (_activeHandle == 1) {
          widget.onChanged(math.min(f, selEnd - 0.001), selEnd);
        } else if (_activeHandle == 2) {
          widget.onChanged(selStart, math.max(f, selStart + 0.001));
        }
      }

      void pick(double f) {
        _activeHandle = (f - selStart).abs() <= (f - selEnd).abs() ? 1 : 2;
        move(f);
      }

      // Calculate tick spacing
      final totalSeconds = widget.durationMs / 1000.0;
      final labelIntervalSec = totalSeconds / 6;
      // ignore: unused_local_variable
      final minorIntervalSec = totalSeconds / 30;

      final startX = xOf(selStart);
      final endX = xOf(selEnd);
      final labelsOverlap = (endX - startX) < labelWidth * 1.2;

      return GestureDetector(
        onTapDown: widget.enabled
            ? (details) => pick(fracOf(details.localPosition.dx))
            : null,
        onHorizontalDragStart: widget.enabled
            ? (details) => pick(fracOf(details.localPosition.dx))
            : null,
        onHorizontalDragUpdate: widget.enabled
            ? (details) => move(fracOf(details.localPosition.dx))
            : null,
        onHorizontalDragEnd: (_) => _activeHandle = 0,
        child: SizedBox(
          height: 104,
          width: width,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // Handle labels
              Positioned(
                left: (startX - labelWidth / 2).clamp(0.0, width - labelWidth),
                top: 0,
                child: _HandleLabel(
                  text: widget.fmt((selStart * widget.durationMs).round()),
                  color: scheme.primary,
                  alignEnd: labelsOverlap,
                ),
              ),
              if (!labelsOverlap)
                Positioned(
                  left: (endX - labelWidth / 2).clamp(0.0, width - labelWidth),
                  top: 0,
                  child: _HandleLabel(
                    text: widget.fmt((selEnd * widget.durationMs).round()),
                    color: scheme.primary,
                    alignEnd: false,
                  ),
                )
              else
                Positioned(
                  right: 0,
                  top: 0,
                  child: _HandleLabel(
                    text: widget.fmt((selEnd * widget.durationMs).round()),
                    color: scheme.primary,
                    alignEnd: false,
                  ),
                ),

              // Main track
              Positioned(
                left: 0,
                right: 0,
                top: 44,
                child: Container(
                  height: 16,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),

              // Cut gaps
              for (final cut in widget.cuts)
                Positioned(
                  left: xOf(cut.$1),
                  width: math.max(2, xOf(cut.$2) - xOf(cut.$1)),
                  top: 44,
                  child: Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),

              // Selection overlay
              Positioned(
                left: xOf(selStart),
                width: math.max(2, xOf(selEnd) - xOf(selStart)),
                top: 40,
                child: Container(
                  height: 24,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),

              // Playhead
              if (widget.previewPos != null)
                Positioned(
                  left: xOf(widget.previewPos!.clamp(0.0, 1.0)) - 1,
                  top: 32,
                  child: Container(
                    width: 2,
                    height: 40,
                    color: scheme.tertiary,
                  ),
                ),

              // Handles
              Positioned(
                left: xOf(selStart) - handleHalf,
                top: 32,
                child: _HandleGlyph(color: scheme.primary),
              ),
              Positioned(
                left: xOf(selEnd) - handleHalf,
                top: 32,
                child: _HandleGlyph(color: scheme.primary),
              ),

              // Minor + major ticks
              Positioned(
                left: 0,
                right: 0,
                top: 66,
                child: SizedBox(
                  height: 16,
                  child: Stack(
                    children: <Widget>[
                      // Minor ticks
                      for (var i = 0; i <= 30; i++)
                        Positioned(
                          left: (i / 30) * width - 0.5,
                          top: 0,
                          child: Container(
                            width: 1,
                            height: 6,
                            color: scheme.outlineVariant,
                          ),
                        ),
                      // Major tick labels
                      for (var i = 0; i <= 6; i++)
                        Positioned(
                          left: (i / 6) * width,
                          top: 8,
                          child: Transform.translate(
                            offset: const Offset(-14, 0),
                            child: Text(
                              widget.fmt(
                                  (i * labelIntervalSec * 1000).round()),
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 9,
                                color: scheme.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _HandleLabel extends StatelessWidget {
  const _HandleLabel({
    required this.text,
    required this.color,
    required this.alignEnd,
  });

  final String text;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _HandleGlyph extends StatelessWidget {
  const _HandleGlyph({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 6),
        ],
      ),
      child: const Icon(Icons.drag_handle_rounded,
          size: 14, color: Colors.white),
    );
  }
}

class _KeepStrip extends StatelessWidget {
  const _KeepStrip({
    required this.keepRegions,
    required this.durationMs,
    required this.isFrench,
  });

  final List<TrimRegion> keepRegions;
  final int durationMs;
  final bool isFrench;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = keepRegions.length;
    final label = isFrench
        ? (count == 0
            ? 'Aucune région conservée'
            : count == 1
                ? '1 région conservée'
                : '$count régions conservées')
        : (count == 0
            ? 'No region kept'
            : count == 1
                ? '1 region kept'
                : '$count regions kept');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 12,
          child: LayoutBuilder(builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              children: <Widget>[
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                for (final region in keepRegions)
                  Positioned(
                    left: (region.startMs / durationMs * width)
                        .clamp(0.0, width)
                        .toDouble(),
                    width: math.max(
                        3,
                        ((region.endMs - region.startMs) /
                                durationMs *
                                width)
                            .clamp(0.0, width)
                            .toDouble()),
                    child: Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
              ],
            );
          }),
        ),
      ],
    );
  }
}