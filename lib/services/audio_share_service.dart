import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/raven_project.dart';
import 'audio_encryption_service.dart';

class AudioShareService {
  AudioShareService({AudioEncryptionService? encryption})
      : _encryption = encryption ?? AudioEncryptionService();

  final AudioEncryptionService _encryption;

  // ---------------------------------------------------------------------------
  // Naming helpers
  // ---------------------------------------------------------------------------

  /// Produces a filesystem-safe display name from arbitrary user text.
  String _sanitizeName(String raw, {int maxLength = 80}) {
    var cleaned = raw
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'^\.+'), '');
    if (cleaned.isEmpty) cleaned = 'RAVEN recording';
    if (cleaned.length > maxLength) {
      cleaned = cleaned.substring(0, maxLength).trim();
    }
    if (cleaned.isEmpty) cleaned = 'RAVEN recording';
    return cleaned;
  }

  /// Returns a safe extension for [session], preferring the recorded format
  /// and falling back to the file's actual extension.
  String _fileExtension(RavenAudioSession session) {
    final format = session.format.toLowerCase();
    if (RegExp(r'^[a-z0-9]{1,10}$').hasMatch(format)) return format;
    final leaf = session.audioPath.split(RegExp(r'[\\/]')).last;
    final fromPath =
        leaf.contains('.') ? leaf.split('.').last.toLowerCase() : '';
    if (RegExp(r'^[a-z0-9]{1,10}$').hasMatch(fromPath)) return fromPath;
    return 'audio';
  }

  /// Builds a distinct user-facing name for a session in a project.
  ///
  /// A take the user renamed gets its own name — the session name always wins
  /// over the project title so sharing a renamed take never exports it under
  /// the project's (old or new) name.
  String _displayNameFor(
    RavenProject project,
    RavenAudioSession session, {
    required int totalSessions,
    required int indexInProject,
  }) {
    final sessionName = session.name.trim();
    // Strip the '<title> · Session <n>' suffix the recorder adds so an
    // auto-named take falls back to the project-title scheme below.
    final autoSuffix = sessionName.indexOf(' · Session ');
    final effectiveName = autoSuffix > 0
        ? sessionName.substring(0, autoSuffix).trim()
        : sessionName;
    if (effectiveName.isNotEmpty &&
        effectiveName != _sanitizeName(project.title)) {
      return _sanitizeName(effectiveName);
    }
    final base = _sanitizeName(project.title);
    if (totalSessions > 1 && indexInProject >= 0) {
      return '$base - Part ${indexInProject + 1}';
    }
    return base;
  }

  /// Creates a fresh temp subdirectory for a single share operation.
  Future<Directory> _createShareDir() async {
    final root = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return Directory(p.join(root.path, 'raven-share-$stamp'))
        .create(recursive: true);
  }

  /// Copies [source] into [dir] with [displayName].[extension].
  /// For encrypted sources, decrypts instead of copying.
  Future<File> _prepareShareCopy({
    required File source,
    required Directory dir,
    required String displayName,
    required String extension,
    required bool encrypted,
    SecretKey? key,
  }) async {
    final target = File(p.join(dir.path, '$displayName.$extension'));
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {}
    }
    if (encrypted) {
      await _encryption.decryptFile(
          input: source, output: target, key: key);
    } else {
      await source.copy(target.path);
    }
    final exists = await target.exists();
    final length = exists ? await target.length() : 0;
    if (!exists || length < 1) {
      throw StateError('The shareable audio copy could not be prepared.');
    }
    return target;
  }

  Future<void> _cleanup(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Future<void> shareSession(
    RavenProject project,
    RavenAudioSession session, {
    SecretKey? key,
  }) async {
    final source = File(session.audioPath);
    if (!await source.exists()) {
      throw FileSystemException(
          'The recording audio file is missing.', session.audioPath);
    }

    final encrypted = project.isAudioProtected ||
        session.audioPath.toLowerCase().endsWith('.ravenenc');
    final totalSessions =
        project.sessions.isEmpty ? 1 : project.sessions.length;
    final index = project.sessions.indexWhere((s) => s.id == session.id);

    final dir = await _createShareDir();
    try {
      final ext = _fileExtension(session);
      final name = _displayNameFor(
        project,
        session,
        totalSessions: totalSessions,
        indexInProject: index,
      );
      final prepared = await _prepareShareCopy(
        source: source,
        dir: dir,
        displayName: name,
        extension: ext,
        encrypted: encrypted,
        key: key,
      );

      await SharePlus.instance.share(ShareParams(
        files: <XFile>[XFile(prepared.path)],
        text: 'RAVEN recording: ${project.title}',
      ));
    } finally {
      await _cleanup(dir);
    }
  }

  Future<void> shareRecording(
    RavenProject project, {
    SecretKey? key,
  }) async {
    if (project.sessions.isEmpty) {
      throw StateError('This recording does not contain an audio file.');
    }

    // Decide whether the stored master can be shared directly.
    final masterPath = project.masterAudioPath;
    File? masterFile;
    if (!project.isAudioProtected &&
        masterPath != null &&
        !masterPath.toLowerCase().endsWith('.ravenenc')) {
      final candidate = File(masterPath);
      if (await candidate.exists()) {
        masterFile = candidate;
      }
    }

    final shareSources =
        <({File file, String ext, String name, bool encrypted})>[];

    if (masterFile != null) {
      final mf = masterFile;
      final leaf = mf.path.split(RegExp(r'[\\/]')).last;
      final rawExt =
          leaf.contains('.') ? leaf.split('.').last.toLowerCase() : '';
      final safeExt =
          RegExp(r'^[a-z0-9]{1,10}$').hasMatch(rawExt) ? rawExt : 'audio';
      shareSources.add((
        file: mf,
        ext: safeExt,
        name: _sanitizeName(project.title),
        encrypted: false,
      ));
    } else {
      final total = project.sessions.length;
      for (var i = 0; i < total; i++) {
        final session = project.sessions[i];
        final source = File(session.audioPath);
        if (!await source.exists()) {
          throw FileSystemException(
              'A recording audio file is missing.', source.path);
        }
        final encrypted = project.isAudioProtected ||
            session.audioPath.toLowerCase().endsWith('.ravenenc');
        shareSources.add((
          file: source,
          ext: _fileExtension(session),
          name: _displayNameFor(
            project,
            session,
            totalSessions: total,
            indexInProject: i,
          ),
          encrypted: encrypted,
        ));
      }
    }

    final dir = await _createShareDir();
    try {
      final prepared = <XFile>[];
      for (final entry in shareSources) {
        final copied = await _prepareShareCopy(
          source: entry.file,
          dir: dir,
          displayName: entry.name,
          extension: entry.ext,
          encrypted: entry.encrypted,
          key: key,
        );
        prepared.add(XFile(copied.path));
      }

      final count = prepared.length;
      await SharePlus.instance.share(ShareParams(
        files: prepared,
        text: count > 1
            ? 'RAVEN recording: ${project.title} ($count parts)'
            : 'RAVEN recording: ${project.title}',
      ));
    } finally {
      await _cleanup(dir);
    }
  }

  /// Shares a single file with its existing name intact. Used for notes
  /// `.txt` and user-picked attachments that already have user-facing names.
  Future<void> shareFile(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('The selected file is missing.', file.path);
    }
    await SharePlus.instance
        .share(ShareParams(files: <XFile>[XFile(file.path)]));
  }

  /// Shares several files at once (used by attachment multi-select).
  Future<void> shareFiles(List<File> files) async {
    final existing = <XFile>[];
    for (final file in files) {
      if (await file.exists()) existing.add(XFile(file.path));
    }
    if (existing.isEmpty) {
      throw StateError('No selected files could be shared.');
    }
    await SharePlus.instance.share(ShareParams(files: existing));
  }
}