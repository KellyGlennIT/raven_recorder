import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/raven_project.dart';
import 'audio_encryption_service.dart';

class AudioShareService {
  AudioShareService({AudioEncryptionService? encryption})
      : _encryption = encryption ?? AudioEncryptionService();

  final AudioEncryptionService _encryption;

  Future<void> shareRecording(RavenProject project) async {
    if (project.sessions.isEmpty) {
      throw StateError('This recording does not contain an audio file.');
    }

    final files = <File>[];
    final temporaryFiles = <File>[];
    try {
      final masterPath = project.masterAudioPath;
      if (!project.isAudioProtected &&
          masterPath != null &&
          !masterPath.endsWith('.ravenenc') &&
          await File(masterPath).exists()) {
        files.add(File(masterPath));
      } else {
        for (final session in project.sessions) {
          final source = File(session.audioPath);
          if (!await source.exists()) {
            throw FileSystemException(
                'A recording audio file is missing.', source.path);
          }
          if (project.isAudioProtected ||
              session.audioPath.endsWith('.ravenenc')) {
            final directory = await getTemporaryDirectory();
            final extension =
                RegExp(r'^[a-zA-Z0-9]{1,10}$').hasMatch(session.format)
                    ? session.format
                    : 'audio';
            final plainPath = p.join(
              directory.path,
              'raven-share-${DateTime.now().microsecondsSinceEpoch}.$extension',
            );
            final temporary = File(plainPath);
            await _encryption.decryptFile(input: source, output: temporary);
            files.add(temporary);
            temporaryFiles.add(temporary);
          } else {
            files.add(source);
          }
        }
      }

      final count = files.length;
      await Share.shareXFiles(
        files.map((file) => XFile(file.path)).toList(),
        text: count > 1
            ? 'RAVEN recording: ${project.title} ($count parts)'
            : 'RAVEN recording: ${project.title}',
      );
    } finally {
      for (final temporary in temporaryFiles) {
        if (await temporary.exists()) await temporary.delete();
      }
    }
  }

  Future<void> shareFile(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('The selected file is missing.', file.path);
    }
    await Share.shareXFiles(<XFile>[XFile(file.path)]);
  }
}
