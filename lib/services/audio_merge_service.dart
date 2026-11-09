import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/raven_project.dart';
import 'wav_recovery_service.dart';

/// Handles merging and format conversion for RAVEN recordings.
///
/// **Two operations:**
///
/// 1. [mergeWavSessions] — pure-Dart PCM16 WAV byte concatenation. No FFmpeg.
///    Works on every platform. Used as the physical merge step: resume
///    appends the new WAV onto the existing WAV(s) into **one** file on disk.
///
/// 2. [convertToFormat] — FFmpeg re-encode between WAV / M4A / MP3 / FLAC.
///    Requires FFmpeg to be bundled on the target platform. On Android this
///    means the `ffmpeg_kit_flutter_new_audio` package must NOT be excluded
///    from the Gradle build (see project README).
///
/// Typical resume pipeline:
///   * convert any non-WAV session → WAV        ([convertToFormat])
///   * merge every WAV session → one WAV        ([mergeWavSessions])
///   * convert the merged WAV → project format  ([convertToFormat])
///   * delete intermediates
///
/// Result: exactly one physical file on disk, in the project's format.
class AudioMergeService {
  /// True when the FFmpeg backend is available for format conversion.
  ///
  /// Pure-Dart WAV merging works regardless of this flag.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.android);

  // ---------------------------------------------------------------------------
  // 1. Pure-Dart WAV merge
  // ---------------------------------------------------------------------------

  /// Losslessly concatenates every PCM16 WAV session in [sessions] into a
  /// single WAV file inside [sessionsDirectory].
  ///
  /// **No FFmpeg, no platform restrictions.** Runs on Android, desktop, iOS.
  ///
  /// **Preconditions** (any failure throws before touching the destination):
  /// - Non-empty [sessions].
  /// - Every session `format` ends with `'wav'`.
  /// - Every file exists and is at least 44 bytes.
  ///
  /// **Safety**: writes to `<target>.merging.tmp`, repairs the RIFF/data
  /// headers via [WavRecoveryService] (which returns the true total duration),
  /// then atomically renames into place. Source files are **not** deleted;
  /// the caller controls cleanup after the project record is committed.
  ///
  /// [onProgress] fires with 0.0 → 1.0 as bytes are read from the sources.
  Future<({File file, int durationMs})> mergeWavSessions({
    required List<RavenAudioSession> sessions,
    required Directory sessionsDirectory,
    String? preferredFileName,
    void Function(double)? onProgress,
  }) async {
    if (sessions.isEmpty) {
      throw ArgumentError('There are no audio sessions to merge.');
    }
    for (final session in sessions) {
      if (!session.format.toLowerCase().endsWith('wav')) {
        throw StateError(
            'Session ${session.id} is ${session.format}, not WAV.');
      }
      final file = File(session.audioPath);
      if (!await file.exists()) {
        throw FileSystemException(
            'A source WAV session is missing.', session.audioPath);
      }
    }
    await sessionsDirectory.create(recursive: true);

    final firstSession = sessions.first;
    final firstLeaf = firstSession.audioPath.split(RegExp(r'[\\/]')).last;
    final targetLeaf = preferredFileName ??
        (firstLeaf.toLowerCase().endsWith('.wav')
            ? firstLeaf
            : '${firstLeaf.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.wav');
    final targetPath = '${sessionsDirectory.path}/$targetLeaf';
    final tempPath = '$targetPath.merging.tmp';

    // Sum lengths up front so we can report merge progress accurately.
    var totalBytes = 0;
    for (final session in sessions) {
      totalBytes += await File(session.audioPath).length();
    }

    final builder = BytesBuilder(copy: false);
    var processedBytes = 0;
    for (var i = 0; i < sessions.length; i++) {
      final bytes = await File(sessions[i].audioPath).readAsBytes();
      if (bytes.length < 44) {
        throw StateError(
            'Session ${sessions[i].id} WAV header is truncated '
            '(${bytes.length} bytes).');
      }
      if (i == 0) {
        builder.add(bytes);
      } else {
        builder.add(Uint8List.sublistView(bytes, 44));
      }
      processedBytes += bytes.length;
      if (totalBytes > 0) {
        onProgress?.call(
            (processedBytes / totalBytes).clamp(0.0, 1.0).toDouble());
      }
    }
    final mergedBytes = builder.toBytes();

    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(mergedBytes, flush: true);

    final durationMs = await WavRecoveryService().repairPcm16File(
      tempFile,
      sampleRate: firstSession.sampleRate,
    );
    if (durationMs == null) {
      try {
        await tempFile.delete();
      } catch (_) {}
      throw StateError('Merged WAV header could not be repaired.');
    }

    final destination = File(targetPath);
    if (await destination.exists()) {
      try {
        await destination.delete();
      } catch (_) {
        // Rename below will throw and the caller falls back.
      }
    }
    await tempFile.rename(targetPath);

    onProgress?.call(1.0);
    return (file: destination, durationMs: durationMs);
  }

  // ---------------------------------------------------------------------------
  // 2. FFmpeg-backed format conversion
  // ---------------------------------------------------------------------------

  /// Converts [input] into the chosen [format] (`'wav' | 'm4a' | 'mp3' | 'flac'`)
  /// and writes the result to [outputPath].
  ///
  /// Requires FFmpeg ([isSupported] must be true).
  ///
  /// **Safety**: writes to `<outputPath>.pending.<ext>` first, verifies the
  /// output is non-empty, then atomically renames into place. The input file
  /// is left untouched — the caller decides when to delete it.
  ///
  /// [onProgress] fires 0.0 → 1.0 from FFmpeg's statistics callback when
  /// available. Falls back to a single jump at completion if statistics are
  /// unavailable on the platform build.
  Future<File> convertToFormat({
    required File input,
    required String outputPath,
    required String format,
    int bitRate = 128000,
    int sampleRate = 44100,
    Duration? estimatedDuration,
    void Function(double)? onProgress,
  }) async {
    if (!await input.exists()) {
      throw FileSystemException('Conversion input is missing.', input.path);
    }
    if (!isSupported) {
      throw UnsupportedError(
          'Format conversion requires FFmpeg on this platform.');
    }

    final extension = _extensionForFormat(format);
    final pending = File('$outputPath.pending.$extension');
    if (await pending.exists()) await pending.delete();

    try {
      final codecArgs = switch (extension) {
        'wav' => '-c:a pcm_s16le',
        'flac' => '-c:a flac',
        'mp3' => '-c:a libmp3lame -b:a ${_safeBitRate(bitRate)}',
        _ => '-c:a aac -b:a ${_safeBitRate(bitRate)} -movflags +faststart',
      };
      final rate = sampleRate.clamp(16000, 48000);
      final command =
          '-hide_banner -nostdin -y -i ${_quote(input.path)} -vn -ar $rate -ac 1 $codecArgs ${_quote(pending.path)}';
      final session = await _ffmpeg.executeWithProgress(
        command,
        estimatedDuration ?? const Duration(hours: 2),
        onProgress,
      );
      final code = await _ffmpeg.returnCode(session);
      if (!_ffmpeg.isSuccess(code)) {
        final logs = await _ffmpeg.output(session);
        throw StateError(
            'Format conversion failed (code ${_ffmpeg.codeValue(code) ?? 'unknown'}). ${_trimLog(logs ?? '')}');
      }
      if (!await pending.exists() || await pending.length() < 64) {
        throw StateError(
            'Format conversion reported success but the output is missing or empty.');
      }
      final destination = File(outputPath);
      if (await destination.exists()) await destination.delete();
      await pending.rename(destination.path);
      onProgress?.call(1.0);
      return destination;
    } finally {
      if (await pending.exists()) {
        try {
          await pending.delete();
        } on FileSystemException {}
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Legacy FFmpeg master merge (kept for API compatibility; not used by the
  // recorder anymore — the resume-merge pipeline produces a single physical
  // file so no "master" wrapper is needed).
  // ---------------------------------------------------------------------------

  Future<File> mergeProject({
    required List<RavenAudioSession> sessions,
    required Directory outputDirectory,
    required String projectId,
    required String format,
    int bitRate = 128000,
    int sampleRate = 44100,
  }) async {
    if (sessions.isEmpty) {
      throw ArgumentError('There are no audio sessions to merge.');
    }
    for (final session in sessions) {
      if (!await File(session.audioPath).exists()) {
        throw FileSystemException(
            'A source recording is missing.', session.audioPath);
      }
      if (session.audioPath.endsWith('.ravenenc')) {
        throw StateError('Protected audio must be decrypted before merging.');
      }
    }
    await outputDirectory.create(recursive: true);
    final extension = _extensionForFormat(format);
    if (!isSupported) {
      throw UnsupportedError(
          'Continuous master audio is created on FFmpeg-capable platforms only.');
    }
    final output = File('${outputDirectory.path}/$projectId.master.$extension');
    final pending =
        File('${outputDirectory.path}/$projectId.master.pending.$extension');
    if (await pending.exists()) await pending.delete();
    try {
      final codecArgs = switch (extension) {
        'wav' => '-c:a pcm_s16le',
        'flac' => '-c:a flac',
        'mp3' => '-c:a libmp3lame -b:a ${_safeBitRate(bitRate)}',
        _ => '-c:a aac -b:a ${_safeBitRate(bitRate)} -movflags +faststart',
      };
      final inputs = sessions
          .map((session) => '-i ${_quote(session.audioPath)}')
          .join(' ');
      final rate = sampleRate.clamp(16000, 48000);
      final normalized = List<String>.generate(
        sessions.length,
        (index) =>
            '[$index:a:0]aresample=$rate,aformat=sample_fmts=fltp:channel_layouts=mono[a$index]',
      );
      final labels =
          List<String>.generate(sessions.length, (index) => '[a$index]').join();
      final filter =
          '${normalized.join(';')};${labels}concat=n=${sessions.length}:v=0:a=1[outa]';
      final command =
          '-hide_banner -nostdin -y $inputs -filter_complex ${_quote(filter)} -map ${_quote('[outa]')} -vn -ar $rate -ac 1 $codecArgs ${_quote(pending.path)}';
      final ffmpegSession = await _ffmpeg.execute(command);
      final code = await _ffmpeg.returnCode(ffmpegSession);
      if (!_ffmpeg.isSuccess(code)) {
        final logs = await _ffmpeg.output(ffmpegSession);
        throw StateError(
            'Audio merge failed (code ${_ffmpeg.codeValue(code) ?? 'unknown'}). ${_trimLog(logs ?? '')}');
      }
      if (!await pending.exists() || await pending.length() < 64) {
        throw StateError(
            'Audio merge reported success but the output is missing or empty.');
      }
      final backup = File('${output.path}.previous');
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          throw FileSystemException(
              'Could not prepare the master-audio backup.', backup.path);
        }
      }
      var movedPreviousMaster = false;
      try {
        if (await output.exists()) {
          await output.rename(backup.path);
          movedPreviousMaster = true;
        }
        await pending.rename(output.path);
      } catch (_) {
        if (movedPreviousMaster &&
            !await output.exists() &&
            await backup.exists()) {
          try {
            await backup.rename(output.path);
          } on FileSystemException {}
        }
        rethrow;
      }
      if (movedPreviousMaster && await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {}
      }
      return output;
    } finally {
      if (await pending.exists()) {
        try {
          await pending.delete();
        } on FileSystemException {}
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  _FfmpegBridge get _ffmpeg => _ffmpegBridge ??= _FfmpegBridge();
  _FfmpegBridge? _ffmpegBridge;

  String _quote(String path) {
    final portable = path.replaceAll('\\', '/');
    return "'${portable.replaceAll("'", "'\\''")}'";
  }

  String _safeBitRate(int bitRate) => '${bitRate.clamp(64000, 320000)}';

  String _extensionForFormat(String format) => switch (format.toLowerCase()) {
        'wav' => 'wav',
        'flac' => 'flac',
        'mp3' => 'mp3',
        _ => 'm4a',
      };

  String _trimLog(String value) {
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= 220
        ? clean
        : '${clean.substring(clean.length - 220)}…';
  }
}

/// Lazily resolved handle to the FFmpeg plugin.
///
/// The plugin types are bound at runtime so a build that does not bundle the
/// native binaries still compiles. Calling [execute] / [executeWithProgress]
/// on such a build throws a clear [UnsupportedError].
class _FfmpegBridge {
  static const String _package = 'package:ffmpeg_kit_flutter_new_audio';

  Future<Object> _load<T>() async {
    try {
      return await _loader.load<T>(_package);
    } catch (error) {
      throw UnsupportedError(
          'FFmpeg is not available on this platform ($error).');
    }
  }

  /// Runs [command] synchronously and returns the completed session.
  Future<Object> execute(String command) async {
    final kit = await _load<Object>();
    return await (kit as dynamic).execute(command) as Future<Object>;
  }

  /// Runs [command] asynchronously with FFmpeg statistics forwarded to
  /// [onProgress]. Falls back to [execute] if the async/statistics API is
  /// not available on the loaded plugin build.
  Future<Object> executeWithProgress(
    String command,
    Duration totalDuration,
    void Function(double)? onProgress,
  ) async {
    final kit = await _load<Object>();
    if (onProgress == null) {
      return await (kit as dynamic).execute(command) as Future<Object>;
    }
    try {
      return await (kit as dynamic).executeAsync(
        command,
        null,
        null,
        (stats) {
          try {
            final timeMs = (stats as dynamic).getTime() as int;
            if (totalDuration.inMilliseconds > 0) {
              final pct =
                  (timeMs / totalDuration.inMilliseconds).clamp(0.0, 1.0);
              onProgress(pct.toDouble());
            }
          } catch (_) {
            // Statistics are best-effort.
          }
        },
      ) as Future<Object>;
    } catch (_) {
      // Plugin build does not support async/statistics — fall back.
      return await (kit as dynamic).execute(command) as Future<Object>;
    }
  }

  Future<Object?> returnCode(Object session) async =>
      await (session as dynamic).getReturnCode() as Object?;

  Future<String?> output(Object session) async =>
      await (session as dynamic).getOutput() as String?;

  bool isSuccess(Object? code) =>
      code != null && (code as dynamic).isValueSuccess() as bool;

  int? codeValue(Object? code) =>
      code == null ? null : (code as dynamic).getValue() as int;

  static const _loader = _DynamicLoader();
}

class _DynamicLoader {
  const _DynamicLoader();

  Future<Object> load<T>(String package) {
    final factory = ffmpegBridgeFactory;
    if (factory == null) {
      throw UnsupportedError('No FFmpeg bridge registered for this build.');
    }
    return Future<Object>.value(factory());
  }
}

/// Set by the app on FFmpeg-capable builds to bind the plugin.
Object Function()? ffmpegBridgeFactory;