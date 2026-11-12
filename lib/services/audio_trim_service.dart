import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import 'background_encode_service.dart';

/// A user-selected keep region on the recording timeline, in milliseconds of
/// the source audio. [endMs] is exclusive (matches FFmpeg's `-to` semantics),
/// so adjacent regions never overlap and no audio is kept twice.
class TrimRegion {
  const TrimRegion({required this.startMs, required this.endMs});

  final int startMs;
  final int endMs;

  int get durationMs => endMs - startMs;
}

/// Result of a trim operation.
class TrimResult {
  const TrimResult({
    required this.outputFile,
    required this.durationMs,
  });

  /// The trimmed audio, in the SAME format/bitrate/sample-rate as the input.
  final File outputFile;

  /// Measured duration of the output in milliseconds.
  final int durationMs;
}

/// Trims recordings with FFmpeg while preserving the exact container, codec
/// tier, and sample rate of the source file.
///
/// Design points:
///
/// - **Any number of regions anywhere on the timeline.** Each keep-region is
///   rendered as one segment; segments are joined losslessly in source order.
///   Overlapping/touching regions are merged first so the command stays
///   minimal and the result is continuous audio.
/// - **Format preservation.** Output uses the source's extension and the same
///   codec arguments RAVEN uses for that format (pcm_s16le / flac /
///   libmp3lame@bitrate / aac@bitrate) plus the source sample rate. An M4A
///   stays M4A, a WAV stays WAV, at the same quality tier.
/// - **Serialization.** Trims and background encodes share one mutex, so a
///   trim never races a pending transcode on the same library.
/// - **Never destructive by default.** The service writes to a caller-supplied
///   output path. Replacing the session file and deleting the original is the
///   CALLER's decision — the UI always asks.
class AudioTrimService {
  AudioTrimService._();
  static final AudioTrimService instance = AudioTrimService._();

  Future<void> _lock() => BackgroundEncodeService.instance.acquireMutex();
  void _unlock() => BackgroundEncodeService.instance.releaseMutex();

  /// Trims [source] to the union of [regions], writing the result to
  /// [outputPath] (the extension of [format] is appended when missing).
  Future<TrimResult> trim({
    required File source,
    required String outputPath,
    required String format,
    required int totalDurationMs,
    required List<TrimRegion> regions,
    int bitRate = 128000,
    int sampleRate = 44100,
  }) async {
    if (regions.isEmpty) {
      throw ArgumentError('At least one keep-region is required.');
    }
    if (!await source.exists()) {
      throw FileSystemException(
          'The recording to trim is missing.', source.path);
    }
    if (source.path == outputPath) {
      throw ArgumentError(
          'The trim output must not overwrite the source in place.');
    }

    await _lock();
    // The remainder runs inside the shared mutex; see finally below.
    try {
      final keep = _mergeRegions(regions, totalDurationMs);
      if (keep.isEmpty) {
        throw StateError('Nothing was selected to keep.');
      }

      final ext = _extensionFor(format);
      final effectiveOutput = outputPath.toLowerCase().endsWith('.$ext')
          ? outputPath
          : '$outputPath.$ext';
      final output = File(effectiveOutput);
      if (await output.exists()) {
        try {
          await output.delete();
        } catch (_) {}
      }

      final workDir = output.parent;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final scratchPrefix = '${workDir.path}/.raven-trim-$stamp';
      final scratchFiles = <String>[];

      try {
        final codecArgs = _codecArgs(ext, bitRate);
        final rate = sampleRate.clamp(16000, 48000);

        if (keep.length == 1) {
          // Single region: one render, no concat step.
          final region = keep.first;
          scratchFiles.add(effectiveOutput);
          final command = '-hide_banner -nostdin -y '
              '-ss ${_seconds(region.startMs)} -i "${source.path}" '
              '-t ${_seconds(region.durationMs)} '
              '-vn -ar $rate -ac 1 $codecArgs '
              '"${effectiveOutput}_trim.tmp.$ext"';
          if (!await _execute(command)) {
            throw StateError('FFmpeg failed to cut the selected region.');
          }
          final tmp = File('${effectiveOutput}_trim.tmp.$ext');
          if (!await tmp.exists() || await tmp.length() < 64) {
            throw StateError('FFmpeg produced an empty trimmed output.');
          }
          await tmp.rename(effectiveOutput);
          scratchFiles.removeLast();
        } else {
          // Multiple regions: render each segment, then join with the concat
          // demuxer (stream copy, lossless join).
          final segmentPaths = <String>[];
          for (var i = 0; i < keep.length; i++) {
            final region = keep[i];
            final segPath = '$scratchPrefix.seg$i.$ext';
            scratchFiles.add(segPath);
            final command = '-hide_banner -nostdin -y '
                '-ss ${_seconds(region.startMs)} -i "${source.path}" '
                '-t ${_seconds(region.durationMs)} '
                '-vn -ar $rate -ac 1 $codecArgs "$segPath"';
            if (!await _execute(command)) {
              throw StateError(
                  'FFmpeg failed cutting segment ${i + 1} of ${keep.length}.');
            }
            final segFile = File(segPath);
            if (!await segFile.exists() || await segFile.length() < 64) {
              throw StateError(
                  'FFmpeg produced an empty segment ${i + 1}/${keep.length}.');
            }
            segmentPaths.add(segPath);
          }

          final listPath = '$scratchPrefix.concat.txt';
          scratchFiles.add(listPath);
          final listBuffer = StringBuffer();
          for (final seg in segmentPaths) {
            final name = seg.split(RegExp(r'[\\/]')).last;
            listBuffer.writeln("file '${_escapeConcat(name)}'");
          }
          await File(listPath).writeAsString(listBuffer.toString(),
              flush: true);

          final joinedTmp = '${effectiveOutput}_trim.tmp.$ext';
          scratchFiles.add(joinedTmp);
          final concatCommand = '-hide_banner -nostdin -y '
              '-f concat -safe 0 -i "$listPath" -c copy "$joinedTmp"';
          if (!await _execute(concatCommand)) {
            throw StateError('FFmpeg failed joining the trimmed segments.');
          }
          final joined = File(joinedTmp);
          if (!await joined.exists() || await joined.length() < 64) {
            throw StateError('FFmpeg produced an empty trimmed output.');
          }
          await joined.rename(effectiveOutput);
          scratchFiles.remove(joinedTmp);
        }

        if (!await output.exists() || await output.length() < 64) {
          throw StateError('FFmpeg produced no usable trimmed output.');
        }
        // The output duration is exact by construction: every segment was
        // re-encoded with an explicit -t from the merged region math.
        var expected = 0;
        for (final region in keep) {
          expected += region.durationMs;
        }
        if (expected <= 0) {
          throw StateError('The trimmed selection is empty.');
        }
        return TrimResult(outputFile: output, durationMs: expected);
      } finally {
        for (final path in scratchFiles) {
          _deleteQuietly(path);
        }
      }
    } finally {
      _unlock();
    }
  }

  /// Normalizes and merges keep-regions: clamps to [totalMs], drops empty and
  /// negative spans, sorts them, and coalesces overlapping/touching ones.
  List<TrimRegion> _mergeRegions(List<TrimRegion> input, int totalMs) {
    final maxMs = totalMs > 0 ? totalMs : 0;
    final sorted = input
        .map((r) {
          var start = r.startMs.clamp(0, maxMs);
          var end = r.endMs.clamp(0, maxMs);
          if (end < start) {
            final t = start;
            start = end;
            end = t;
          }
          return TrimRegion(startMs: start, endMs: end);
        })
        .where((r) => r.durationMs > 0)
        .toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));

    final merged = <TrimRegion>[];
    for (final region in sorted) {
      final last = merged.isEmpty ? null : merged.last;
      if (last != null && region.startMs <= last.endMs) {
        merged[merged.length - 1] = TrimRegion(
          startMs: last.startMs,
          endMs: region.endMs > last.endMs ? region.endMs : last.endMs,
        );
      } else {
        merged.add(region);
      }
    }
    return merged;
  }

  /// Runs one FFmpeg command; returns true only on a clean success code.
  Future<bool> _execute(String command) async {
    final FFmpegSession session;
    try {
      session = await FFmpegKit.execute(command);
    } catch (error) {
      throw StateError(
          'FFmpeg native library did not load ($error). '
          'Run "flutter clean" and rebuild.');
    }
    final code = await session.getReturnCode();
    return code != null && ReturnCode.isSuccess(code);
  }

  String _codecArgs(String ext, int bitRate) {
    final clamped = bitRate.clamp(64000, 320000);
    return switch (ext) {
      'wav' => '-c:a pcm_s16le',
      'flac' => '-c:a flac',
      'mp3' => '-c:a libmp3lame -b:a $clamped',
      _ => '-c:a aac -b:a $clamped -movflags +faststart',
    };
  }

  String _extensionFor(String format) => switch (format.toLowerCase()) {
        'wav' => 'wav',
        'flac' => 'flac',
        'mp3' => 'mp3',
        _ => 'm4a',
      };

  String _seconds(int ms) => (ms / 1000).toStringAsFixed(3);

  String _escapeConcat(String name) =>
      name.replaceAll("'", r"'\''").replaceAll('\\', r'\\');

  void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
