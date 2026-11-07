import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/raven_project.dart';
import 'project_repository.dart';

/// Validates an untrusted portable ZIP path before it is joined to a local
/// staging/project directory. Directory entries with a trailing slash are
/// allowed; traversal, absolute paths, drive-qualified paths and empty segments
/// are rejected.
bool isSafeRelativeArchivePath(String path) {
  if (path.isEmpty) return false;
  final portable = path.replaceAll('\\', '/');
  // Check original segments before normalization: normalizing `a/../b` first
  // would hide the traversal attempt while later joins may use the raw path.
  if (portable.startsWith('/') || p.isAbsolute(path) || portable.contains(':')) return false;
  final segments = portable.split('/');
  if (portable.endsWith('/')) segments.removeLast();
  if (segments.isEmpty || segments.any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
    return false;
  }
  if (portable.contains('\u0000')) return false;
  return true;
}

/// Portable project bundle service. Exports a project record and all files in
/// its private project directory. Import is staged and validated before files
/// are installed; callers must resolve ID collisions through the repository.
class ProjectArchiveService {
  const ProjectArchiveService(this._repository);
  final ProjectRepository _repository;
  static const String _manifestName = 'raven-project-bundle.json';
  static const int _maxEntries = 20000;

  Future<File> exportProject(RavenProject project) async {
    if (project.isAudioProtected || project.sessions.any((session) => session.audioPath.endsWith('.ravenenc'))) {
      throw StateError('This project contains audio encrypted with a device-local key. Decrypt the audio before exporting a portable project bundle.');
    }
    final projectDirectory = Directory(p.join(_repository.projectsDirectory.path, project.id));
    if (!await projectDirectory.exists()) {
      throw FileSystemException('Project files are missing.', projectDirectory.path);
    }

    final archive = Archive();
    // Absolute paths and public MediaStore URIs are device-specific. Keep them
    // in the local index, but never embed them in a portable project manifest.
    final portableProject = Map<String, Object?>.from(project.toJson())
      ..remove('masterAudioPath')
      ..remove('publicCopyLocation');
    // Store source paths relative to the project bundle, never the originating
    // device's absolute private-storage location. The importer must remap these
    // relative paths into the final project directory during installation.
    portableProject['sessions'] = project.sessions.map((session) {
      final json = Map<String, Object?>.from(session.toJson());
      json['audioPath'] = p.posix.join('sessions', p.posix.basename(session.audioPath.replaceAll('\\', '/')));
      return json;
    }).toList();
    final manifest = <String, Object?>{
      'format': 'raven-project-bundle',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'project': portableProject,
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile(_manifestName, manifestBytes.length, manifestBytes));

    await for (final entity in projectDirectory.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: projectDirectory.path).replaceAll('\\', '/');
      if (!_isSafeRelativePath(relative)) continue;
      // Master files are reproducible caches, not source-of-truth recordings.
      // Do not bundle stale masters or rollback/pending files; the importer can
      // rebuild a master from the original source sessions.
      if (p.basename(relative).startsWith('${project.id}.master.')) continue;
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile('project_files/$relative', bytes.length, bytes));
    }

    final bytes = ZipEncoder().encode(archive);
    if (bytes == null) throw const FileSystemException('Could not create project archive.');
    final temp = await getTemporaryDirectory();
    final output = File(p.join(temp.path, 'RAVEN-${_safeName(project.title)}-${project.id}.raven.zip'));
    await output.writeAsBytes(bytes, flush: true);
    return output;
  }

  Future<void> shareProject(RavenProject project) async {
    final file = await exportProject(project);
    await Share.shareXFiles(<XFile>[XFile(file.path)], text: 'RAVEN project: ${project.title}');
  }

  /// Installs a staged import as a new project with a fresh stable ID.
  /// Device-specific state (PIN requirement, encryption flag, master path and
  /// public copy URI) is intentionally reset; imported audio remains private.
  Future<RavenProject> installStagedImport(StagedProjectImport staged) async {
    final newId = _repository.newId();
    final destinationRoot = await _repository.createProjectDirectory(newId);
    late final RavenProject imported;
    try {
      await for (final entity in staged.directory.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: staged.directory.path).replaceAll('\\', '/');
        if (!_isSafeRelativePath(relative)) {
          throw FormatException('Unsafe staged import path: $relative');
        }
        final destination = File(p.join(destinationRoot.path, relative));
        await destination.parent.create(recursive: true);
        await entity.copy(destination.path);
      }

      final installedSessions = <RavenAudioSession>[];
      for (final audioSession in staged.project.sessions) {
        final relative = audioSession.audioPath.replaceAll('\\', '/');
        if (!_isSafeRelativePath(relative) || !relative.startsWith('sessions/')) {
          throw FormatException('Invalid relative audio path in project manifest: $relative');
        }
        final installedAudio = File(p.join(destinationRoot.path, relative));
        if (!await installedAudio.exists()) {
          throw FileSystemException('The imported project is missing an audio source.', installedAudio.path);
        }
        installedSessions.add(audioSession.copyWith(audioPath: installedAudio.path));
      }

      imported = RavenProject(
        id: newId,
        title: staged.project.title,
        createdAt: staged.project.createdAt,
        updatedAt: DateTime.now(),
        sessions: installedSessions,
        category: staged.project.category,
        isFavorite: staged.project.isFavorite,
        isTrashed: false,
        isDraft: false,
        notes: staged.project.notes,
        tags: List<String>.from(staged.project.tags),
        bookmarks: List<RavenBookmark>.from(staged.project.bookmarks),
        isAudioProtected: false,
        requiresAppPin: false,
        aiGeneratedContent: Map<String, String>.from(staged.project.aiGeneratedContent),
        masterAudioPath: null,
        publicCopyLocation: null,
      );
      await _repository.add(imported);
    } catch (_) {
      // Until the project index commits, the new directory is an unreferenced
      // staging destination and can be safely rolled back.
      if (await destinationRoot.exists()) {
        try { await destinationRoot.delete(recursive: true); } on FileSystemException { /* retain data for manual recovery */ }
      }
      rethrow;
    }

    // Staging cleanup is housekeeping; it must never roll back an already
    // committed project if the OS refuses to remove the temporary directory.
    try { await staged.discard(); } catch (_) { /* stale staging folder can be cleaned later */ }
    return imported;
  }

  /// Validates a bundle and extracts it into a private staging directory.
  /// It deliberately does not overwrite an existing project automatically.
  Future<StagedProjectImport> stageImport(File bundle) async {
    if (!await bundle.exists()) throw FileSystemException('Bundle not found.', bundle.path);
    final bytes = await bundle.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.files.length > _maxEntries) {
      throw const FormatException('This archive contains too many entries.');
    }
    ArchiveFile? manifestEntry;
    for (final entry in archive.files) {
      if (!_isSafeRelativePath(entry.name)) {
        throw FormatException('Unsafe path in project bundle: ${entry.name}');
      }
      if (entry.name == _manifestName && entry.isFile) manifestEntry = entry;
    }
    if (manifestEntry == null) throw const FormatException('This is not a RAVEN project bundle.');
    final manifestText = utf8.decode(manifestEntry.content as List<int>);
    final decoded = jsonDecode(manifestText);
    if (decoded is! Map || decoded['format'] != 'raven-project-bundle' || decoded['version'] != 1 || decoded['project'] is! Map) {
      throw const FormatException('Unsupported RAVEN project bundle format.');
    }
    final project = RavenProject.fromJson(Map<String, Object?>.from(decoded['project'] as Map));
    final stagingRoot = Directory(p.join((await getTemporaryDirectory()).path, 'raven-import-${DateTime.now().microsecondsSinceEpoch}'));
    await stagingRoot.create(recursive: true);
    try {
      for (final entry in archive.files) {
        if (!entry.isFile || !entry.name.startsWith('project_files/')) continue;
        final relative = entry.name.substring('project_files/'.length);
        if (!_isSafeRelativePath(relative)) throw FormatException('Unsafe project file path: $relative');
        final destination = File(p.join(stagingRoot.path, relative));
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(entry.content as List<int>, flush: true);
      }
      return StagedProjectImport(project: project, directory: stagingRoot);
    } catch (_) {
      if (await stagingRoot.exists()) await stagingRoot.delete(recursive: true);
      rethrow;
    }
  }

  bool _isSafeRelativePath(String path) => isSafeRelativeArchivePath(path);

  String _safeName(String value) {
    final safe = value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '-').replaceAll(RegExp(r'-+'), '-');
    final trimmed = safe.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.isEmpty ? 'project' : (trimmed.length > 48 ? trimmed.substring(0, 48) : trimmed);
  }
}

class StagedProjectImport {
  const StagedProjectImport({required this.project, required this.directory});
  final RavenProject project;
  final Directory directory;

  Future<void> discard() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
