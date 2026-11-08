import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

import '../models/raven_project.dart';

/// Builds one user-facing master audio file from a project's ordered source
/// sessions. Originals are deliberately retained as recovery sources.
class AudioMergeService {
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
      final session = await FFmpegKit.execute(command);
      final code = await session.getReturnCode();
      if (!ReturnCode.isSuccess(code)) {
        final logs = await session.getOutput();
        throw StateError(
            'Audio merge failed (code ${code?.getValue() ?? 'unknown'}). ${_trimLog(logs ?? '')}');
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
