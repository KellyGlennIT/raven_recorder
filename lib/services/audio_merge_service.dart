import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';

import '../models/raven_project.dart';

class AudioMergeService {
  static bool get isSupported => !kIsWeb;

  // ---------------------------------------------------------------------------
  // Pure-Dart WAV byte-merge (no FFmpeg)
  // ---------------------------------------------------------------------------

  /// Losslessly concatenates every PCM16 WAV session into one WAV file.
  ///
  /// Uses proper RIFF chunk parsing so it works with WAVEFORMATEX and
  /// WAVE_FORMAT_EXTENSIBLE headers, not just the 44-byte standard layout.
  ///
  /// The merged file's header is written directly — no repairPcm16File call,
  /// which would corrupt a freshly-merged header and produce silent playback.
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

    var totalBytes = 0;
    for (final session in sessions) {
      totalBytes += await File(session.audioPath).length();
    }

    final builder = BytesBuilder(copy: false);
    var processed = 0;
    Uint8List? firstHeader;
    int? dataOffsetInHeader;
    final sampleBytes = BytesBuilder(copy: false);

    for (var i = 0; i < sessions.length; i++) {
      final bytes = await File(sessions[i].audioPath).readAsBytes();
      final dataOffset = _wavDataOffset(bytes);
      if (dataOffset < 0 || dataOffset >= bytes.length) {
        throw StateError(
            'Session ${sessions[i].id} is not a valid WAV file '
            '(data chunk not found).');
      }
      if (i == 0) {
        firstHeader = Uint8List.fromList(bytes.sublist(0, dataOffset));
        dataOffsetInHeader = dataOffset;
      }
      sampleBytes.add(Uint8List.sublistView(bytes, dataOffset));
      processed += bytes.length;
      if (totalBytes > 0) {
        onProgress?.call(
            (processed / totalBytes).clamp(0.0, 1.0).toDouble());
      }
    }

    final firstHeaderBytes = firstHeader!;
    final payload = sampleBytes.toBytes();
    final totalLength = firstHeaderBytes.length + payload.length;

    builder.add(firstHeaderBytes);
    builder.add(payload);
    final merged = builder.toBytes();

    // Patch RIFF size (offset 4) and data-chunk size (dataOffset - 4).
    _writeUint32LE(merged, 4, totalLength - 8);
    _writeUint32LE(merged, dataOffsetInHeader! - 4, payload.length);

    final durationMs =
        _wavDurationFromHeaderAndData(firstHeaderBytes, payload.length);
    if (durationMs <= 0) {
      throw StateError('Merged WAV duration could not be computed.');
    }

    final firstLeaf = sessions.first.audioPath.split(RegExp(r'[\\/]')).last;
    final targetLeaf = preferredFileName ??
        (firstLeaf.toLowerCase().endsWith('.wav')
            ? firstLeaf
            : '${firstLeaf.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.wav');
    final targetPath = '${sessionsDirectory.path}/$targetLeaf';
    final tempPath = '$targetPath.merging.tmp';
    final tempFile = File(tempPath);
    await tempFile.writeAsBytes(merged, flush: true);
    final destination = File(targetPath);
    if (await destination.exists()) {
      try {
        await destination.delete();
      } catch (_) {}
    }
    await tempFile.rename(targetPath);

    onProgress?.call(1.0);
    return (file: destination, durationMs: durationMs);
  }

  // ---------------------------------------------------------------------------
  // FFmpeg-backed format conversion — direct call, no bridge
  // ---------------------------------------------------------------------------

  /// Converts [input] into [format] (`'wav' | 'm4a' | 'mp3' | 'flac'`) and
  /// writes the result to [outputPath].
  ///
  /// Calls [FFmpegKit.execute] directly. The package bundles prebuilt native
  /// libraries for Android, iOS, macOS, Windows, and Linux — no bridge, no
  /// custom loader, no external setup required.
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
          '-hide_banner -nostdin -y -i "${input.path}" '
          '-vn -ar $rate -ac 1 $codecArgs "${pending.path}"';

      final FFmpegSession session;
      try {
        session = await FFmpegKit.execute(command);
      } catch (e) {
        // Native library failed to load. Almost always means the Gradle
        // exclusion for ffmpeg-kit-audio is still active in the build.
        throw StateError(
            'FFmpeg native library did not load ($e). '
            'Run "flutter clean" and rebuild. Also verify '
            'android/app/build.gradle.kts does NOT contain an "exclude" '
            'block for "com.antonkarpenko:ffmpeg-kit-audio".');
      }

      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getOutput();
        throw StateError(
            'FFmpeg conversion failed (code ${returnCode?.getValue() ?? 'unknown'}). '
            '${_trimLog(logs ?? '')}');
      }
      if (!await pending.exists() || await pending.length() < 64) {
        throw StateError(
            'FFmpeg reported success but the output is missing or empty.');
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
        } on FileSystemException {
          // Cleanup is best-effort; a leftover pending file is harmless.
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Legacy API — kept for compile compatibility, now throws clearly
  // ---------------------------------------------------------------------------

  Future<File> mergeProject({
    required List<RavenAudioSession> sessions,
    required Directory outputDirectory,
    required String projectId,
    required String format,
    int bitRate = 128000,
    int sampleRate = 44100,
  }) async {
    throw UnsupportedError(
        'mergeProject is no longer used. The recorder uses '
        'mergeWavSessions + convertToFormat instead.');
  }

  // ---------------------------------------------------------------------------
  // WAV chunk parsing
  // ---------------------------------------------------------------------------

  /// Returns the byte offset where the audio data begins in [bytes],
  /// or -1 if [bytes] is not a valid RIFF/WAVE with a `data` chunk.
  int _wavDataOffset(Uint8List bytes) {
    if (bytes.length < 12) return -1;
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return -1;
    if (String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') return -1;
    final data = bytes.buffer.asByteData(bytes.offsetInBytes);
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      if (id == 'data') {
        return offset + 8;
      }
      // Guard against corrupt headers that claim an impossibly large size.
      if (size > bytes.length) return -1;
      offset += 8 + size;
      if (size % 2 == 1) offset += 1; // RIFF pad byte for odd-sized chunks
    }
    return -1;
  }

  /// Parses a WAV header and computes the duration of [dataLength] bytes of
  /// sample data. Returns 0 if the header is not parseable.
  int _wavDurationFromHeaderAndData(Uint8List header, int dataLength) {
    if (header.length < 44) return 0;
    final data = header.buffer.asByteData(header.offsetInBytes);
    if (String.fromCharCodes(header.sublist(12, 16)) != 'fmt ') return 0;
    final channels = data.getUint16(22, Endian.little);
    final sampleRate = data.getUint32(24, Endian.little);
    final bitsPerSample = data.getUint16(34, Endian.little);
    if (channels == 0 || sampleRate == 0 || bitsPerSample == 0) return 0;
    final bytesPerSecond = sampleRate * channels * (bitsPerSample ~/ 8);
    if (bytesPerSecond == 0) return 0;
    return ((dataLength / bytesPerSecond) * 1000).round();
  }

  void _writeUint32LE(Uint8List bytes, int offset, int value) {
    bytes[offset] = value & 0xFF;
    bytes[offset + 1] = (value >> 8) & 0xFF;
    bytes[offset + 2] = (value >> 16) & 0xFF;
    bytes[offset + 3] = (value >> 24) & 0xFF;
  }

  String _extensionForFormat(String format) => switch (format.toLowerCase()) {
        'wav' => 'wav',
        'flac' => 'flac',
        'mp3' => 'mp3',
        _ => 'm4a',
      };

  String _safeBitRate(int bitRate) => '${bitRate.clamp(64000, 320000)}';

  String _trimLog(String value) {
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= 220
        ? clean
        : '…${clean.substring(clean.length - 220)}';
  }
}