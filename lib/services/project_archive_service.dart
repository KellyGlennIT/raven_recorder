import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/raven_project.dart';
import 'project_repository.dart';
import 'audio_share_service.dart';

/// Validates that a path inside a ZIP file is safe to extract.
/// Prevents "Zip Slip" path traversal attacks.
bool isSafeRelativeArchivePath(String path) {
  if (path.isEmpty) return false;

  // Reject absolute paths and drive letters
  if (path.startsWith('/') ||
      path.startsWith('\\') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(path)) {
    return false;
  }

  // Normalize separators and check for double slashes
  final normalized = path.replaceAll('\\', '/');
  if (normalized.contains('//')) return false;

  // Reject traversal segments
  final parts = normalized.split('/');
  for (final part in parts) {
    if (part == '..' || part == '.') return false;
  }

  return true;
}

class StagedProjectImport {
  StagedProjectImport(this.tempDir, this.originalBundleName);
  final Directory tempDir;
  final String originalBundleName;

  Future<void> discard() async {
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

class ProjectArchiveService {
  ProjectArchiveService(this._repository);
  final ProjectRepository _repository;

  /// Extracts a ZIP file into a temporary staging directory safely.
  Future<StagedProjectImport> stageImport(File bundle) async {
    final tempRoot = await Directory.systemTemp.createTemp('raven_import_');
    InputFileStream? inputStream;

    try {
      // Stream extraction (memory safe)
      inputStream = InputFileStream(bundle.path);
      final archive = ZipDecoder().decodeStream(inputStream);

      for (final file in archive) {
        if (!file.isFile) continue;

        if (!isSafeRelativeArchivePath(file.name)) {
          throw const FormatException('Archive contains unsafe paths.');
        }

        final outPath = p.join(tempRoot.path, file.name);

        // Write each entry to disk and release its buffered content so a large
        // archive never has to be held in memory all at once.
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
        file.clear();
      }

      // Verify it looks like a RAVEN project
      final jsonFile = File(p.join(tempRoot.path, 'metadata', 'project.json'));
      if (!await jsonFile.exists()) {
        throw const FormatException('Missing metadata/project.json');
      }

      return StagedProjectImport(
        tempRoot,
        p.basename(bundle.path),
      );
    } catch (e) {
      try {
        if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      try {
        inputStream?.close();
      } catch (_) {}
    }
  }

  /// A helper to unzip a project that was zipped inside another zip (recursive import)
  Future<File?> extractNestedBundle(File bundle) async {
    // This is generally handled by the UI asking the user to extract first.
    return null;
  }

  /// Installs the extracted temp folder into the main repository.
  Future<RavenProject> installStagedImport(StagedProjectImport staged) async {
    final jsonFile =
        File(p.join(staged.tempDir.path, 'metadata', 'project.json'));
    final jsonStr = await jsonFile.readAsString();
    final data = jsonDecode(jsonStr);
    if (data is! Map) {
      throw const FormatException('Invalid metadata/project.json');
    }

    var project = RavenProject.fromJson(Map<String, Object?>.from(data));

    // Generate new ID to prevent collisions
    final newId = _repository.newId();
    project = project.copyWith(
      title: '${project.title} (Imported)',
      updatedAt: DateTime.now(),
    );

    // Move files to proper location
    final projectDir =
        Directory(p.join(_repository.projectsDirectory.path, newId));
    await projectDir.create(recursive: true);

    final sessionsDir = Directory(p.join(staged.tempDir.path, 'sessions'));
    if (await sessionsDir.exists()) {
      await sessionsDir.rename(p.join(projectDir.path, 'sessions'));
    }

    final notesDir = Directory(p.join(staged.tempDir.path, 'notes'));
    if (await notesDir.exists()) {
      await notesDir.rename(p.join(projectDir.path, 'notes'));
    }

    final attachmentsDir =
        Directory(p.join(staged.tempDir.path, 'attachments'));
    if (await attachmentsDir.exists()) {
      await attachmentsDir.rename(p.join(projectDir.path, 'attachments'));
    }

    // Fix session paths
    final newSessions = project.sessions.map((s) {
      final fileName = s.audioPath.split(RegExp(r'[\\/]')).last;
      return s.copyWith(
        audioPath: p.join(projectDir.path, 'sessions', fileName),
      );
    }).toList();

    final oldMasterPath = project.masterAudioPath;
    project = project.copyWith(
      sessions: newSessions,
      masterAudioPath: oldMasterPath == null
          ? null
          : p.join(
              projectDir.path,
              'sessions',
              oldMasterPath.split(RegExp(r'[\\/]')).last,
            ),
      clearMasterAudioPath: oldMasterPath == null,
      // Exported public paths point at the sender's machine and are invalid
      // here; the import lands in the private projects directory.
      clearPublicCopyLocation: true,
      clearPublicFolderLocation: true,
    );

    try {
      await _repository.add(project);
    } catch (_) {
      try {
        if (await projectDir.exists()) await projectDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    await staged.discard();
    return project;
  }

  /// Exports a project folder as a ZIP file and opens the share sheet.
  Future<void> shareProject(RavenProject project) async {
    final projectFolder = await _repository.ensureProjectFolder(project);
    if (!await projectFolder.exists()) {
      throw StateError('Project folder not found.');
    }

    final tempDir = await Directory.systemTemp.createTemp('raven_export_');
    final safeTitle = project.title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final zipPath = p.join(tempDir.path, '$safeTitle.zip');

    try {
      // Stream compression to disk
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);

      try {
        // Write project.json
        final jsonFile = File(p.join(tempDir.path, 'project.json'));
        await jsonFile.writeAsString(jsonEncode(project.toJson()));

        encoder.addFile(jsonFile, 'metadata/project.json');

        // Add all other files from the project folder into the root of the ZIP
        encoder.addDirectory(projectFolder, includeDirName: false);
      } finally {
        encoder.close();
      }

      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        throw StateError('The project archive could not be created.');
      }

      // Share the zip
      await AudioShareService().shareFile(zipFile);
    } finally {
      // Clean up the temporary zip file after sharing completes
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Archives the whole RAVEN library (projects, recordings, notes,
  /// attachments, encrypted files and the project index) into a single ZIP and
  /// opens the share sheet so the user can save it to a cloud drive.
  Future<void> backupAllData() async {
    final projectsDir = _repository.projectsDirectory;
    final rootDir = projectsDir.parent;
    if (!await rootDir.exists()) {
      throw StateError('The RAVEN library folder could not be found.');
    }

    // Build the archive outside the RAVEN folder so the ZIP never contains
    // itself. systemTemp (not getTemporaryDirectory) keeps it off Android's
    // app cache when the library itself lives on external storage.
    final tempDir = await Directory.systemTemp.createTemp('raven_backup_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final zipPath = p.join(tempDir.path, 'RAVEN_Backup_$stamp.zip');

    try {
      // Stream compression straight to disk so a large library never has to
      // fit in memory. Partial and abandoned temp files are skipped.
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);

      try {
        await encoder.addDirectory(
          rootDir,
          includeDirName: false,
          filter: (entity, progress) {
            final name = entity.uri.pathSegments.isEmpty
                ? ''
                : entity.uri.pathSegments.last.toLowerCase();
            final skip = name.endsWith('.tmp') ||
                name.endsWith('.pending') ||
                name.endsWith('.merging') ||
                name.endsWith('.bak');
            return skip ? ZipFileOperation.skip : ZipFileOperation.include;
          },
        );
      } finally {
        encoder.close();
      }

      final zipFile = File(zipPath);
      if (!await zipFile.exists() || await zipFile.length() < 256) {
        throw StateError('The backup archive could not be created.');
      }

      await AudioShareService().shareFile(zipFile);
    } finally {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }
}
