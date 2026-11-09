import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/raven_project.dart';

/// Builds one user-facing master audio file from a project's ordered source
/// sessions. Originals are deliberately retained as recovery sources.
///
/// The `ffmpeg_kit_flutter_new_audio` package is excluded from Android builds
/// (`platform_plugins: false` in pubspec) because it is desktop-only and would
/// otherwise add large unused native libraries to the APK. Its types are loaded
/// dynamically so that simply referencing this service never forces the plugin
/// into the Android binary. On Android the merge is skipped and playback
/// falls back to the continuous session playlist, which is equivalent to the
/// README's documented master-failure path.
class AudioMergeService {
  /// FFmpeg is only bundled on desktop targets in this project.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

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
    final extension = switch (format.toLowerCase()) {
      'wav' => 'wav',
      'flac' => 'flac',
      'mp3' => 'mp3',
      _ => 'm4a',
    };
    if (!isSupported) {
      throw UnsupportedError(
          'Continuous master audio is created on desktop only. Sessions are played as one timeline on this device.');
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
      // Commit only after FFmpeg finalized a non-empty file. Keep the previous
      // master as a rollback copy until the new file is in place; deleting the
      // old file before rename could lose it if a filesystem operation fails.
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
          } on FileSystemException {
            // The backup remains on disk for manual/recovery handling.
          }
        }
        rethrow;
      }
      if (movedPreviousMaster && await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // The new master is valid. A stale backup is safe to clean later.
        }
      }
      return output;
    } finally {
      if (await pending.exists()) {
        try {
          await pending.delete();
        } on FileSystemException {/* keep source sessions intact */}
      }
    }
  }

  _FfmpegBridge get _ffmpeg => _ffmpegBridge ??= _FfmpegBridge();
  _FfmpegBridge? _ffmpegBridge;

  String _quote(String path) {
    final portable = path.replaceAll('\\', '/');
    return "'${portable.replaceAll("'", "'\\''")}'";
  }

  String _safeBitRate(int bitRate) => '${bitRate.clamp(64000, 320000)}';
  String _trimLog(String value) {
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= 220
        ? clean
        : '${clean.substring(clean.length - 220)}…';
  }
}

/// Lazily resolved handle to the desktop-only FFmpeg plugin.
///
/// The plugin types are bound at runtime so Android does not need the native
/// package to be present. If a build includes this file without the plugin
/// (e.g. a platform without a packaged FFmpeg binary), the call fails with a
/// clear [UnsupportedError] instead of a missing-method crash.
class _FfmpegBridge {
  static const String _package = 'package:ffmpeg_kit_flutter_new_audio';

  Future<Object> _load<T>() async {
    try {
      return await _loader.load<T>(_package);
    } catch (error) {
      throw UnsupportedError(
          'Continuous audio merging is not available on this platform ($error).');
    }
  }

  Future<Object> execute(String command) async {
    final kit = await _load<Object>();
    return (kit as dynamic).execute(command) as Future<Object>;
  }

  Future<Object?> returnCode(Object session) async =>
      await (session as dynamic).getReturnCode() as Object?;

  Future<String?> output(Object session) async =>
      await (session as dynamic).getOutput() as String?;

  bool isSuccess(Object? code) => code != null && (code as dynamic).isValueSuccess() as bool;

  int? codeValue(Object? code) => code == null ? null : (code as dynamic).getValue() as int;

  static const _loader = _DynamicLoader();
}

/// Minimal wrapper so the plugin import stays out of the app's static graph.
class _DynamicLoader {
  const _DynamicLoader();

  Future<Object> load<T>(String package) {
    // The plugin registers its own types; Dart cannot import it lazily, so the
    // desktop build wires the concrete implementation through this hook.
    final factory = ffmpegBridgeFactory;
    if (factory == null) {
      throw UnsupportedError('No FFmpeg bridge registered for this build.');
    }
    return Future<Object>.value(factory());
  }
}

/// Set by `main.dart` on desktop builds to bind the FFmpeg plugin.
Object Function()? ffmpegBridgeFactory;
