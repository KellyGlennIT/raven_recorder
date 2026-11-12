import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';

import 'background_encode_service.dart';

class TrimRegion {
  const TrimRegion({required this.startMs, required this.endMs});
  final int startMs;
  final int endMs;
  int get durationMs => endMs - startMs;
}

class TrimResult {
  const TrimResult({required this.outputFile, required this.durationMs});
  final File outputFile;
  final int durationMs;
}

class AudioTrimService {
  AudioTrimService._();
  static final AudioTrimService instance = AudioTrimService._();

  Future<void> _lock() => BackgroundEncodeService.instance.acquireMutex();
  void _unlock() => BackgroundEncodeService.instance.releaseMutex();

  /// Trims [source] to the union of [regions], writing the result to
  /// [outputPath]. Preserves the source's codec tier and sample rate.
  ///
  /// [onProgress] fires in `[0.0, 1.0]` roughly 4–8 times per second with a
  /// short stage description suitable for a UI label.
  Future<TrimResult> trim({
    required File source,
    required String outputPath,
    required String format,
    required int totalDurationMs,
    required List<TrimRegion> regions,
    int bitRate = 128000,
    int sampleRate = 44100,
    void Function(double progress, String stage)? onProgress,
  }) async {
    if (regions.isEmpty) {
      throw ArgumentError('At least one keep-region is required.');
    }
    if (!await source.exists()) {
      throw FileSystemException('The recording to trim is missing.', source.path);
    }
    if (source.path == outputPath) {
      throw ArgumentError('The trim output must not overwrite the source.');
    }

    await _lock();
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
        } catch (_) {
          // Best-effort cleanup of a stale output.
        }
      }

      final workDir = output.parent;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final tempPath = '${workDir.path}/.raven-trim-$stamp.$ext';

      try {
        final codecArgs = _codecArgs(ext, bitRate);
        final rate = sampleRate.clamp(16000, 48000);
        final command = _buildCommand(
          source: source,
          outputPath: tempPath,
          regions: keep,
          codecArgs: codecArgs,
          sampleRate: rate,
        );

        final totalMs = keep.fold<int>(0, (s, r) => s + r.durationMs);
        final success = await _executeWithProgress(
          command,
          totalMs: totalMs,
          onProgress: onProgress,
        );
        if (!success) {
          throw StateError('FFmpeg failed to render the trimmed audio.');
        }

        final tmp = File(tempPath);
        if (!await tmp.exists() || await tmp.length() < 128) {
          throw StateError('FFmpeg produced an empty trimmed output.');
        }
        await tmp.rename(effectiveOutput);

        if (!await output.exists() || await output.length() < 128) {
          throw StateError('Trimmed audio failed verification.');
        }

        onProgress?.call(1.0, 'Done');
        return TrimResult(outputFile: output, durationMs: totalMs);
      } finally {
        try {
          final tmp = File(tempPath);
          if (await tmp.exists()) await tmp.delete();
        } on FileSystemException {
          // Best-effort cleanup.
        }
      }
    } finally {
      _unlock();
    }
  }

  String _buildCommand({
    required File source,
    required String outputPath,
    required List<TrimRegion> regions,
    required String codecArgs,
    required int sampleRate,
  }) {
    if (regions.length == 1) {
      final r = regions.first;
      return '-hide_banner -nostdin -y -i "${source.path}" '
          '-ss ${_sec(r.startMs)} -t ${_sec(r.durationMs)} '
          '-vn -ar $sampleRate -ac 1 $codecArgs "$outputPath"';
    }

    // Multiple regions: build a filter graph that atrims each segment and
    // concatenates them. Single FFmpeg invocation, no temp files.
    final buffer = StringBuffer();
    for (var i = 0; i < regions.length; i++) {
      final r = regions[i];
      if (i > 0) buffer.write(';');
      buffer.write(
        '[0:a]atrim=start=${_sec(r.startMs)}:end=${_sec(r.endMs)},'
        'asetpts=PTS-STARTPTS[a${i + 1}]',
      );
    }
    final concatInputs =
        List<String>.generate(regions.length, (i) => '[a${i + 1}]').join();
    buffer.write(
      ';${concatInputs}concat=n=${regions.length}:v=0:a=1[out]',
    );
    return '-hide_banner -nostdin -y -i "${source.path}" '
        '-filter_complex "${buffer.toString()}" '
        '-map "[out]" -vn -ar $sampleRate -ac 1 $codecArgs "$outputPath"';
  }

  Future<bool> _executeWithProgress(
    String command, {
    required int totalMs,
    void Function(double progress, String stage)? onProgress,
  }) async {
    final completer = Completer<FFmpegSession>();
    try {
      await FFmpegKit.executeAsync(
        command,
        (FFmpegSession session) {
          if (!completer.isCompleted) completer.complete(session);
        },
        null,
        totalMs > 0
            ? (Statistics stats) {
                final encodedMs = stats.getTime();
                if (encodedMs > 0) {
                  onProgress?.call(
                    (encodedMs / totalMs).clamp(0.0, 1.0).toDouble(),
                    'Trimming',
                  );
                }
              }
            : null,
      );
    } catch (error) {
      throw StateError(
          'FFmpeg native library did not load ($error). '
          'Run "flutter clean" and rebuild.');
    }

    final session = await completer.future;
    final code = await session.getReturnCode();
    return code != null && ReturnCode.isSuccess(code);
  }

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

  String _sec(int ms) => (ms / 1000).toStringAsFixed(3);
}