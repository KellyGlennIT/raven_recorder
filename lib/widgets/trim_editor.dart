import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/audio_trim_service.dart';

/// Result returned to the caller after a successful trim.
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

/// Full-screen trim editor for one recording.
///
/// UX model (kept deliberately simple):
/// - A timeline bar shows the whole recording; draggable handles define the
///   span to operate on (default: everything).
/// - "Cut selection" removes the selected span from the keep-set; "Keep only
///   selection" reduces the keep-set to the selected span. Edits compose, so
///   users can remove many pieces from anywhere in the timeline.
/// - The strip below the timeline shows every remaining keep-region and every
///   cut gap, so the result is never a surprise.
/// - "Play selection" previews just the selected span.
/// - Saving ALWAYS asks: "Replace original" or "Save as new take" — the
///   original is never destroyed unless the user chooses that, and the output
///   keeps the source's format, bitrate and sample rate.
class TrimEditor extends StatefulWidget {
  const TrimEditor({
    required this.source,
    required this.format,
    required this.durationMs,
    required this.bitRate,
    required this.sampleRate,
    required this.title,
    required this.isFrench,
    super.key,
  });

  final File source;
  final String format;
  final int durationMs;
  final int bitRate;
  final int sampleRate;
  final String title;
  final bool isFrench;

  @override
  State<TrimEditor> createState() => _TrimEditorState();
}

class _TrimEditorState extends State<TrimEditor> {
  late final AudioPlayer _player;

  // Selection in fractions of the timeline [0..1].
  double _selStart = 0.0;
  double _selEnd = 1.0;

  // Applied cuts, as fractions of the timeline.
  List<(double, double)> _cuts = <(double, double)>[];

  bool _processing = false;
  bool _previewing = false;
  StreamSubscription<Duration>? _posSub;
  Duration _previewPos = Duration.zero;

  String label(String en, String fr) => widget.isFrench ? fr : en;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  int get _durationMs => widget.durationMs > 0 ? widget.durationMs : 1;
  int get _startMs => (_selStart * _durationMs).round();
  int get _endMs => (_selEnd * _durationMs).round();

  bool get _hasCuts => _cuts.isNotEmpty;

  /// Keep-regions in ms after applying every cut to the full timeline.
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

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _playSelection() async {
    if (_processing) return;
    try {
      _posSub?.cancel();
      await _player.stop();
      await _player.setAudioSource(AudioSource.uri(Uri.file(widget.source.path)));
      await _player.seek(Duration(milliseconds: _startMs));
      unawaited(_player.play());
      _previewing = true;
      _posSub = _player.positionStream.listen((pos) {
        final ms = pos.inMilliseconds;
        if (ms >= _endMs) {
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
      if (mounted) setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${label('Preview failed', 'Échec de la préécoute')}: $error'),
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

  void _applyCutSelection() {
    if (_endMs - _startMs >= _durationMs) return; // Cutting everything.
    setState(() {
      _cuts = [..._cuts, (_selStart, _selEnd)];
    });
  }

  /// "Keep only selection": everything OUTSIDE the selection is cut.
  void _applyKeepOnlySelection() {
    if (_selStart <= 0.001 && _selEnd >= 0.999) return;
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

  Future<void> _save() async {
    final regions = _keepRegions;
    if (regions.isEmpty) return;
    final total = _durationMs;
    final unchanged = regions.length == 1 &&
        regions.first.startMs <= 0 &&
        regions.first.endMs >= total;

    final choice = await showDialog<_TrimSaveChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(_hasCuts || !unchanged
            ? Icons.content_cut_rounded
            : Icons.info_outline_rounded),
        title: Text(label(
          _hasCuts || !unchanged ? 'Save trimmed audio' : 'Nothing to trim',
          _hasCuts || !unchanged
              ? 'Enregistrer l’audio rogné'
              : 'Rien à rogner',
        )),
        content: Text(
          unchanged && !_hasCuts
              ? label(
                  'No region has been cut yet. Drag the handles or add cuts first.',
                  'Aucune région rognée. Déplacez les poignées ou ajoutez des coupes d’abord.')
              : label(
                  'Keep ${_fmt(_keptMs)} of ${_fmt(total)}.\n\n'
                  'How should the trimmed audio be saved? Your original stays untouched unless you choose to replace it.',
                  'Garder ${_fmt(_keptMs)} sur ${_fmt(total)}.\n\n'
                  'Comment enregistrer l’audio rogné ? L’original reste intact sauf si vous choisissez de le remplacer.'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(label('Cancel', 'Annuler')),
          ),
          if (!unchanged || _hasCuts) ...<Widget>[
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _TrimSaveChoice.saveAsNew),
              child: Text(label('Save as new take', 'Nouvelle prise')),
            ),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.pop(dialogContext, _TrimSaveChoice.replace),
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: Text(label('Replace original', 'Remplacer l’original')),
            ),
          ],
        ],
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _processing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ext = _extensionFor(widget.format);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final parent = widget.source.parent;
      final targetPath = choice == _TrimSaveChoice.replace
          ? '${parent.path}/.raven-trim-out-$stamp.$ext'
          : '${parent.path}/${_sanitizeName(widget.title)}-trimmed-$stamp.$ext';

      final result = await AudioTrimService.instance.trim(
        source: widget.source,
        outputPath: targetPath,
        format: widget.format,
        totalDurationMs: total,
        regions: regions,
        bitRate: widget.bitRate,
        sampleRate: widget.sampleRate,
      );

      if (!mounted) return;
      Navigator.of(context).pop(TrimEditorResult(
        file: result.outputFile,
        durationMs: result.durationMs,
        replacedOriginal: choice == _TrimSaveChoice.replace,
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(
        content: Text(
            '${label('Could not trim recording', 'Impossible de rogner l’enregistrement')}: $error'),
      ));
      if (mounted) setState(() => _processing = false);
    }
  }

  String _extensionFor(String format) => switch (format.toLowerCase()) {
        'wav' => 'wav',
        'flac' => 'flac',
        'mp3' => 'mp3',
        _ => 'm4a',
      };

  String _sanitizeName(String value) => value
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), '_');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectionMs = _endMs - _startMs;

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
              onPressed: _processing
                  ? null
                  : (_cuts.isEmpty && _selStart == 0.0 && _selEnd == 1.0
                      ? null
                      : _resetAll),
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        widget.title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_fmt(widget.durationMs)} · '
                        '${widget.format.toUpperCase()} · '
                        '${label('Trimmed length', 'Durée rognée')} ${_fmt(_keptMs)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 20),

                      // --- Timeline ---------------------------------------
                      _TimelineBar(
                        durationMs: _durationMs,
                        selStart: _selStart,
                        selEnd: _selEnd,
                        cuts: _cuts,
                        previewPos: _previewing
                            ? _previewPos.inMilliseconds / _durationMs
                            : null,
                        enabled: !_processing,
                        onChanged: (start, end) =>
                            setState(() {
                              _selStart = start;
                              _selEnd = end;
                            }),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Text(
                            label('Selection', 'Sélection'),
                            style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${_fmt(_startMs)} → ${_fmt(_endMs)}  '
                            '(${_fmt(selectionMs)})',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontFeatures: const [],
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),

                      // --- Keep/cut strip ---------------------------------
                      const SizedBox(height: 16),
                      _KeepStrip(
                        keepRegions: _keepRegions,
                        durationMs: _durationMs,
                      ),

                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.center,
                        children: <Widget>[
                          OutlinedButton.icon(
                            onPressed: _processing ? null : _applyCutSelection,
                            icon: const Icon(Icons.content_cut_rounded, size: 18),
                            label: Text(label('Cut selection', 'Couper')),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                _processing ? null : _applyKeepOnlySelection,
                            icon: const Icon(Icons.crop_rounded, size: 18),
                            label: Text(label('Keep only', 'Garder seul')),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                _processing || _cuts.isEmpty ? null : _undoLastCut,
                            icon: const Icon(Icons.undo_rounded, size: 18),
                            label: Text(label('Undo cut', 'Annuler la coupe')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _processing
                            ? null
                            : (_previewing ? _stopPreview : _playSelection),
                        icon: Icon(_previewing
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded),
                        label: Text(_previewing
                            ? label('Stop preview', 'Arrêter')
                            : label('Play selection', 'Écouter la sélection')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _processing ? null : _save,
                        icon: _processing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.save_rounded),
                        label: Text(_processing
                            ? label('Trimming…', 'Rognage…')
                            : label('Save trimmed audio',
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

enum _TrimSaveChoice { replace, saveAsNew }

// ---------------------------------------------------------------------------
// Timeline bar with draggable handles
// ---------------------------------------------------------------------------

class _TimelineBar extends StatefulWidget {
  const _TimelineBar({
    required this.durationMs,
    required this.selStart,
    required this.selEnd,
    required this.cuts,
    required this.previewPos,
    required this.enabled,
    required this.onChanged,
  });

  final int durationMs;
  final double selStart;
  final double selEnd;
  final List<(double, double)> cuts;
  final double? previewPos;
  final bool enabled;
  final void Function(double start, double end) onChanged;

  @override
  State<_TimelineBar> createState() => _TimelineBarState();
}

class _TimelineBarState extends State<_TimelineBar> {
  /// Handle locked for the current gesture: 0 = none, 1 = start, 2 = end.
  /// Locked at drag-start so crossing the midpoint mid-gesture never flips
  /// the handles under the user's finger.
  int _activeHandle = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selStart = widget.selStart;
    final selEnd = widget.selEnd;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      const handleHalf = 14.0;

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
        _activeHandle =
            (f - selStart).abs() <= (f - selEnd).abs() ? 1 : 2;
        move(f);
      }

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
          height: 84,
          width: width,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // Base track
              Positioned(
                left: 0,
                right: 0,
                top: 34,
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
                  top: 34,
                  child: Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              // Selected span
              Positioned(
                left: xOf(selStart),
                width: math.max(2, xOf(selEnd) - xOf(selStart)),
                top: 30,
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
                  top: 22,
                  child: Container(
                    width: 2,
                    height: 40,
                    color: scheme.tertiary,
                  ),
                ),
              // Handles
              Positioned(
                left: xOf(selStart) - handleHalf,
                top: 20,
                child: _HandleGlyph(color: scheme.primary),
              ),
              Positioned(
                left: xOf(selEnd) - handleHalf,
                top: 20,
                child: _HandleGlyph(color: scheme.primary),
              ),
              // Time ticks
              Positioned(
                left: 0,
                right: 0,
                top: 62,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('0:00',
                        style: Theme.of(context).textTheme.labelSmall),
                    Text(
                      '${widget.durationMs ~/ 60000}:${((widget.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
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
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
          ),
        ],
      ),
      child: const Icon(Icons.drag_handle_rounded,
          size: 14, color: Colors.white),
    );
  }
}

/// Visual summary of what stays and what is removed.
class _KeepStrip extends StatelessWidget {
  const _KeepStrip({required this.keepRegions, required this.durationMs});

  final List<TrimRegion> keepRegions;
  final int durationMs;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${keepRegions.length} ${keepRegions.length == 1 ? 'region kept' : 'regions kept'}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 10,
          child: LayoutBuilder(builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              children: <Widget>[
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: scheme.errorContainer.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                for (final region in keepRegions)
                  Positioned(
                    left: (region.startMs / durationMs * width)
                        .clamp(0.0, width)
                        .toDouble(),
                    width: math.max(
                        3,
                        ((region.endMs - region.startMs) / durationMs * width)
                            .clamp(0.0, width)
                            .toDouble()),
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(5),
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
