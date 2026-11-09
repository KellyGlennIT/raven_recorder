import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/raven_project.dart';
import 'audio_encryption_service.dart';
import 'project_repository.dart';

class AudioProtectionService {
  AudioProtectionService({
    required ProjectRepository repository,
    AudioEncryptionService? encryption,
  })  : _repository = repository,
        _encryption = encryption ?? AudioEncryptionService();

  final ProjectRepository _repository;
  final AudioEncryptionService _encryption;

  Future<RavenProject> encrypt(RavenProject project) async {
    if (project.isAudioProtected) return project;
    if (project.publicCopyLocation != null) {
      throw StateError(
        'Remove the public copy before encrypting this recording.',
      );
    }
    if (project.sessions.isEmpty) {
      throw StateError('This recording does not contain audio to encrypt.');
    }

    final encryptedPaths = <String, String>{};
    try {
      for (final session in project.sessions) {
        if (session.audioPath.endsWith('.ravenenc')) {
          throw StateError(
              'The recording metadata is inconsistent with its encrypted audio file.');
        }
        final source = File(session.audioPath);
        if (!await source.exists()) {
          throw FileSystemException(
              'A recording audio file is missing.', source.path);
        }
        final destination = File('${source.path}.ravenenc');
        await _encryption.encryptFile(input: source, output: destination);
        encryptedPaths[session.id] = destination.path;
      }

      final protected = project.copyWith(
        isAudioProtected: true,
        sessions: project.sessions
            .map((session) =>
                session.copyWith(audioPath: encryptedPaths[session.id]!))
            .toList(),
        clearMasterAudioPath: true,
      );
      await _repository.update(protected);

      for (final session in project.sessions) {
        final original = File(session.audioPath);
        if (await original.exists()) await original.delete();
      }
      final master = project.masterAudioPath;
      if (master != null &&
          !project.sessions.any((s) => s.audioPath == master)) {
        final masterFile = File(master);
        if (await masterFile.exists()) await masterFile.delete();
      }
      return protected;
    } catch (error) {
      if (_repository.projectById(project.id)?.isAudioProtected != true) {
        for (final path in encryptedPaths.values) {
          final encrypted = File(path);
          if (await encrypted.exists()) await encrypted.delete();
        }
      }
      rethrow;
    }
  }

  Future<RavenProject> decrypt(RavenProject project) async {
    if (!project.isAudioProtected) return project;
    final restoredPaths = <String, String>{};
    try {
      for (final session in project.sessions) {
        final source = File(session.audioPath);
        if (!await source.exists()) {
          throw FileSystemException(
              'An encrypted recording audio file is missing.', source.path);
        }
        final restoredPath = session.audioPath.endsWith('.ravenenc')
            ? session.audioPath
                .substring(0, session.audioPath.length - '.ravenenc'.length)
            : p.join(
                source.parent.path,
                '${session.id}.${session.format}',
              );
        final restored = File(restoredPath);
        if (await restored.exists()) {
          throw FileSystemException(
              'A file already exists at the decrypted audio path.',
              restored.path);
        }
        await _encryption.decryptFile(input: source, output: restored);
        restoredPaths[session.id] = restored.path;
      }

      final unprotected = project.copyWith(
        isAudioProtected: false,
        sessions: project.sessions
            .map((session) =>
                session.copyWith(audioPath: restoredPaths[session.id]!))
            .toList(),
      );
      await _repository.update(unprotected);
      for (final session in project.sessions) {
        final encrypted = File(session.audioPath);
        if (await encrypted.exists()) await encrypted.delete();
      }
      return unprotected;
    } catch (_) {
      if (_repository.projectById(project.id)?.isAudioProtected == true) {
        for (final path in restoredPaths.values) {
          final plaintext = File(path);
          if (await plaintext.exists()) await plaintext.delete();
        }
      }
      rethrow;
    }
  }
}
