import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_audio/statistics.dart';

import 'background_encode_service.dart';

/// Professional noise removal built on FFmpeg's FFT denoiser.
///
/// The filter chain is:
///   * `highpass=f=80` — removes DC offset and low rumble (AC hum, desk
///     vibration, wind) below the voice band.
///   * `afftdn=nf=-25` — spectral (FFT) denoiser that learns the broadband
///     noise floor and subtracts it (fans, hiss, traffic).
///
/// Rendering is streamed to disk by FFmpeg, so memory use stays flat no matter
/// how long the recording is.
class AudioCleanService {
  AudioCleanService._();
  static final AudioCleanService instance = AudioCleanService._();

  /// Filters applied to every cleaned recording.
  static const String filterChain = 'highpass=f=80,afftdn=nf=-25';

  Future<void> _lock() => BackgroundEncodeService.instance.acquireMutex();
  void _unlock() => BackgroundEncodeService.instance.releaseMutex();

  /// Renders a denoised copy of [input] to [outputPath].
  ///
  /// [durationMs] improves progress accuracy; pass the known session length.
  /// The output is written atomically: a temporary file is produced first and
  /// only renamed into place after it passes verification.
  Future<File> cleanAudio({
    required File input,
    required String outputPath,
    required String format,
    int bitRate = 128000,
    int sampleRate = 44100,
    int durationMs = 0,
    void Function(double progress)? onProgress,
  }) async {
    if (!await input.exists()) {
      throw FileSystemException('Audio file is missing.', input.path);
    }
    if (input.absolute.path == File(outputPath).absolute.path) {
      throw ArgumentError('The cleaned output must be a different file.');
    }

    await _lock();
    try {
      final ext = _extensionFor(format);
      final pending = File('$outputPath.pending.$ext');
      if (await pending.exists()) await pending.delete();

      final codecArgs = _codecArgs(ext, bitRate);
      final formatArg = _formatArg(ext);
      final rate = sampleRate.clamp(16000, 48000);
      final totalMs = durationMs > 0 ? durationMs : 0;
      final useStats = totalMs > 0 && onProgress != null;

      final command = '-hide_banner -nostdin -y -i "${input.path}" '
          '-vn -ar $rate -ac 1 -af "$filterChain" '
          '$codecArgs $formatArg "${pending.path}"';

      final completer = Completer<FFmpegSession>();
      try {
        await FFmpegKit.executeAsync(
          command,
          (FFmpegSession session) {
            if (!completer.isCompleted) completer.complete(session);
          },
          null,
          useStats
              ? (Statistics stats) {
                  final encodedMs = stats.getTime();
                  if (encodedMs > 0) {
                    onProgress(
                        (encodedMs / totalMs).clamp(0.0, 0.99).toDouble());
                  }
                }
              : null,
        );
      } catch (e) {
        throw StateError('FFmpeg native library did not load ($e).');
      }

      final session = await completer.future;
      final code = await session.getReturnCode();
      final success = ReturnCode.isSuccess(code) &&
          await pending.exists() &&
          await pending.length() >= 128;

      if (!success) {
        final logs = await session.getOutput() ?? '';
        final tail =
            logs.length > 400 ? logs.substring(logs.length - 400) : logs;
        try {
          if (await pending.exists()) await pending.delete();
        } on FileSystemException {
          // Best-effort cleanup of the failed render.
        }
        throw StateError(
            'FFmpeg failed to clean the audio (code ${code?.getValue() ?? 'unknown'}). $tail');
      }

      final destination = File(outputPath);
      if (await destination.exists()) await destination.delete();
      await pending.rename(destination.path);
      onProgress?.call(1.0);
      return destination;
    } finally {
      _unlock();
    }
  }

  String _codecArgs(String ext, int bitRate) {
    final clamped = bitRate.clamp(64000, 320000);
    return switch (ext) {
      'wav' => '-c:a pcm_s16le',
      'flac' => '-c:a flac',
      'mp3' => '-c:a libmp3lame -b:a ${clamped}k',
      _ => '-c:a aac -b:a ${clamped}k -movflags +faststart',
    };
  }

  String _formatArg(String extension) => switch (extension) {
        'mp3' => '-f mp3',
        'flac' => '-f flac',
        'wav' => '-f wav',
        _ => '-f ipod',
      };

  String _extensionFor(String format) => switch (format.toLowerCase()) {
        'wav' => 'wav',
        'flac' => 'flac',
        'mp3' => 'mp3',
        _ => 'm4a',
      };
}
