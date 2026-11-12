import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/raven_project.dart';
import 'audio_visibility_service.dart';
import 'wav_recovery_service.dart';

class ProjectRepository {
  ProjectRepository._(this._rootDirectory);

  final Directory _rootDirectory;
  final List<RavenProject> _projects = <RavenProject>[];
  final List<String> _categories = <String>['Uncategorized'];
  final Uuid _uuid = const Uuid();

  List<RavenProject> get projects => List<RavenProject>.unmodifiable(_projects);
  List<String> get categories => List<String>.unmodifiable(_categories);
  RavenProject? projectById(String id) {
    for (final project in _projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  /// Folder where full multi-session **projects** are stored, each in their
  /// own named sub-directory with sessions/, notes/, attachments/ etc.
  Directory get projectsDirectory =>
      Directory('${_rootDirectory.path}/projects');

  /// Flat root for **standalone recordings** — single audio files live
  /// directly here, alongside projects.json / categories.json, with no
  /// intermediate `recordings/` folder and no per-recording sub-folder.
  /// Completely separate from [projectsDirectory] so the two types never
  /// share a folder.
  Directory get recordingsDirectory => _rootDirectory;

  static Future<ProjectRepository> create() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final ravenDirectory = Directory('${supportDirectory.path}/raven');
    await ravenDirectory.create(recursive: true);
    final repository = ProjectRepository._(ravenDirectory);
    await repository.projectsDirectory.create(recursive: true);
    await Directory('${ravenDirectory.path}/categories')
        .create(recursive: true);
    await repository.load();
    return repository;
  }

  String newId() => _uuid.v4();

  Future<Directory?> _publicProjectsRoot() async {
    try {
      Directory? base;
      if (Platform.isAndroid) {
        final musicDir = Directory('/storage/emulated/0/Music');
        if (await musicDir.exists()) {
          return Directory('${musicDir.path}/RAVEN');
        }
        base = await getExternalStorageDirectory();
        if (base == null) return null;
        return Directory('${base.path}/RAVEN');
      } else if (Platform.isIOS || Platform.isMacOS) {
        base = await getApplicationDocumentsDirectory();
      } else if (Platform.isWindows || Platform.isLinux) {
        base = await getDownloadsDirectory();
        base ??= await getApplicationDocumentsDirectory();
      } else {
        base = await getApplicationDocumentsDirectory();
      }
      return Directory('${base.path}/RAVEN');
    } on Exception {
      // No user-visible storage available; callers surface a clear error.
      return null;
    }
  }

  Future<String?> publicProjectsRootPath() async {
    final dir = await _publicProjectsRoot();
    return dir?.path;
  }

  String privateProjectsRootPath() => projectsDirectory.path;

  Future<Directory> _resolveProjectFolder(RavenProject project) async {
    final public = project.publicFolderLocation;
    if (project.hasPublicFolder && public != null && public.isNotEmpty) {
      return Directory(public);
    }
    return Directory(
        '${projectsDirectory.path}/${projectFolderName(project)}');
  }

  Future<Directory> createProjectDirectory(String projectId) async {
    final directory = Directory('${projectsDirectory.path}/$projectId');
    await directory.create(recursive: true);
    for (final child in <String>[
      'sessions',
      'notes',
      'attachments',
      'exports',
      'metadata'
    ]) {
      await Directory('${directory.path}/$child').create(recursive: true);
    }
    return directory;
  }

  Future<Directory> ensureProjectFolder(RavenProject project) async {
    if (project.isStandalone) {
      await recordingsDirectory.create(recursive: true);
      return recordingsDirectory;
    }
    final folder = await _resolveProjectFolder(project);
    await _createEmptyProjectTree(folder);
    return folder;
  }

  String projectFolderName(RavenProject project) {
    final base = _safeFolderName(project.title);
    final shortId = project.id.length > 8
        ? project.id.substring(0, 8)
        : project.id;
    final defaultPrefix = project.isStandalone ? 'Recording' : 'Project';
    return '${base.isEmpty ? defaultPrefix : base}-$shortId';
  }

  Future<void> _createEmptyProjectTree(Directory folder) async {
    await folder.create(recursive: true);
    for (final child in <String>[
      'sessions',
      'notes',
      'attachments',
      'exports',
      'metadata'
    ]) {
      await Directory('${folder.path}/$child').create(recursive: true);
    }
  }

  Future<void> _moveDirectory(Directory from, Directory to) async {
    if (from.path == to.path) return;
    try {
      await from.rename(to.path);
      return;
    } on FileSystemException {
      // Cross-filesystem or locked; fall through to copy-then-delete.
    }
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = entity.path
          .substring(from.path.length)
          .replaceFirst(RegExp(r'^[\\/]+'), '');
      if (relative.isEmpty) continue;
      if (entity is File) {
        final dest = File('${to.path}/$relative');
        await dest.parent.create(recursive: true);
        await entity.copy(dest.path);
      } else if (entity is Directory) {
        await Directory('${to.path}/$relative').create(recursive: true);
      }
    }
    try {
      await from.delete(recursive: true);
    } on FileSystemException {
      // Best-effort: the copy succeeded, source cleanup is housekeeping.
    }
  }

  Future<RavenProject> toggleVisibility(
    RavenProject project, {
    required bool makePublic,
  }) async {
    if (project.isAudioProtected && makePublic) {
      throw StateError(
          'Encrypted projects cannot be made public. Remove the password '
          'first, or copy the recording with Share instead.');
    }
    if (project.requiresAppPin && makePublic) {
      throw StateError(
          'PIN-locked recordings cannot be made public. Remove the individual '
          'PIN requirement first.');
    }

    final currentlyPublic = project.hasPublicFolder;
    if (currentlyPublic == makePublic) return project;

    if (project.isStandalone) {
      final session = project.sessions.isEmpty ? null : project.sessions.first;
      if (session == null) return project;

      final Directory newRoot;
      if (makePublic) {
        final public = await _publicProjectsRoot();
        if (public == null) {
          throw StateError(
              'Public storage is not available on this device. Check that '
              'external storage is mounted and try again.');
        }
        newRoot = public;
      } else {
        newRoot = recordingsDirectory;
      }
      await newRoot.create(recursive: true);

      final sourceFile = File(session.audioPath);
      final ext = session.audioPath.contains('.')
          ? session.audioPath.split('.').last
          : session.format;
      final leaf = '${_safeFolderName(project.title)}-${project.id.substring(0, 8)}.$ext';
      final destFile = File('${newRoot.path}/$leaf');

      if (await sourceFile.exists()) {
        try {
          await sourceFile.rename(destFile.path);
        } on FileSystemException {
          await sourceFile.copy(destFile.path);
          try {
            await sourceFile.delete();
          } on FileSystemException {
            // Best-effort: copy succeeded, source cleanup can be retried later.
          }
        }
      }

      final newPath = destFile.path;
      final updatedSession = session.copyWith(audioPath: newPath);
      return project.copyWith(
        sessions: <RavenAudioSession>[updatedSession],
        clearMasterAudioPath: true,
        publicFolderLocation: makePublic ? newPath : null,
        clearPublicFolderLocation: !makePublic,
      );
    }

    final oldFolder = await _resolveProjectFolder(project);
    final oldPath = oldFolder.path;

    final Directory newRoot;
    if (makePublic) {
      final public = await _publicProjectsRoot();
      if (public == null) {
        throw StateError(
            'Public storage is not available on this device. Check that '
            'external storage is mounted and try again.');
      }
      newRoot = public;
    } else {
      newRoot = projectsDirectory;
    }
    await newRoot.create(recursive: true);

    final newFolder =
        Directory('${newRoot.path}/${projectFolderName(project)}');

    if (await oldFolder.exists()) {
      if (oldFolder.path != newFolder.path) {
        await _moveDirectory(oldFolder, newFolder);
      }
    } else {
      await _createEmptyProjectTree(newFolder);
    }

    final updatedSessions = <RavenAudioSession>[];
    for (final session in project.sessions) {
      if (session.audioPath.startsWith(oldPath)) {
        updatedSessions.add(session.copyWith(
          audioPath:
              session.audioPath.replaceFirst(oldPath, newFolder.path),
        ));
      } else {
        updatedSessions.add(session);
      }
    }

    String? updatedMaster = project.masterAudioPath;
    if (updatedMaster != null && updatedMaster.startsWith(oldPath)) {
      updatedMaster =
          updatedMaster.replaceFirst(oldPath, newFolder.path);
    }

    return project.copyWith(
      sessions: updatedSessions,
      masterAudioPath: updatedMaster,
      clearMasterAudioPath: updatedMaster == null,
      publicFolderLocation: makePublic ? newFolder.path : null,
      clearPublicFolderLocation: !makePublic,
    );
  }

      Future<RavenProject> renameProject(RavenProject project, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('The project title must not be empty.');
    }
    if (trimmed == project.title) return project;

    final renamedRecord = project.copyWith(title: trimmed);

    // ── Standalone: rename the AUDIO FILE on disk (no folder).
    // The file naming convention is `<sanitised-title>-<sessionId>.<ext>`,
    // matching what renameSessionFile already uses. Public standalones keep
    // publicFolderLocation in sync with the new file path (it points to the
    // live file for standalones, not a folder).
    if (project.isStandalone) {
      final sanitized = _safeFolderName(trimmed);
      final fileTitle = sanitized.isEmpty ? 'Recording' : sanitized;
      final newSessions = <RavenAudioSession>[];
      for (final session in project.sessions) {
        final source = File(session.audioPath);
        if (!await source.exists()) {
          newSessions.add(session);
          continue;
        }
        final ext = session.audioPath.contains('.')
            ? session.audioPath.split('.').last
            : session.format;
        final target =
            File('${source.parent.path}/$fileTitle-${session.id}.$ext');
        if (target.path == source.path) {
          newSessions.add(session);
          continue;
        }
        try {
          if (await target.exists()) {
            try {
              await target.delete();
            } on FileSystemException {
              // Best-effort cleanup before the rename attempt.
            }
          }
          await source.rename(target.path);
          newSessions.add(session.copyWith(audioPath: target.path));
        } on FileSystemException {
          try {
            await source.copy(target.path);
            await source.delete();
            newSessions.add(session.copyWith(audioPath: target.path));
          } on FileSystemException {
            // Both rename and copy failed; keep the original path so audio
            // stays playable. The title change still applies to the record.
            newSessions.add(session);
          }
        }
      }
      final updatedPublic =
          (project.hasPublicFolder && newSessions.isNotEmpty)
              ? newSessions.first.audioPath
              : project.publicFolderLocation;
      return renamedRecord.copyWith(
        sessions: newSessions,
        publicFolderLocation: updatedPublic,
      );
    }

    // ── Project: rename the FOLDER + rewrite all session paths.
    final oldFolder = await _resolveProjectFolder(project);

    if (!await oldFolder.exists()) {
      try {
        await ensureProjectFolder(renamedRecord);
      } on FileSystemException {
        // The display rename still applies even if the folder can't be built.
      }
      return renamedRecord;
    }

    final sameFolder = project.hasPublicFolder;
    final Directory newFolder;
    if (sameFolder) {
      final parent = oldFolder.parent;
      newFolder =
          Directory('${parent.path}/${projectFolderName(renamedRecord)}');
    } else {
      newFolder = Directory(
          '${projectsDirectory.path}/${projectFolderName(renamedRecord)}');
    }

    if (oldFolder.path == newFolder.path) return renamedRecord;

    try {
      if (await newFolder.exists()) {
        await _moveDirectory(oldFolder, newFolder);
      } else {
        try {
          await oldFolder.rename(newFolder.path);
        } on FileSystemException {
          await _moveDirectory(oldFolder, newFolder);
        }
      }
    } on FileSystemException catch (e) {
      throw StateError(
          'Could not rename project folder from "${oldFolder.path}" to '
          '"${newFolder.path}": $e');
    }

    final oldPath = oldFolder.path;
    String rewrite(String path) => path.startsWith(oldPath)
        ? newFolder.path + path.substring(oldPath.length)
        : path;

    return renamedRecord.copyWith(
      sessions: renamedRecord.sessions
          .map((session) =>
              session.copyWith(audioPath: rewrite(session.audioPath)))
          .toList(),
      masterAudioPath: renamedRecord.masterAudioPath == null
          ? null
          : rewrite(renamedRecord.masterAudioPath!),
      publicFolderLocation:
          sameFolder ? newFolder.path : renamedRecord.publicFolderLocation,
    );
  }
  Future<RavenProject> renameSessionFile(
    RavenProject project,
    RavenAudioSession session,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return project;

    final index = project.sessions.indexWhere((s) => s.id == session.id);
    if (index < 0) return project;

    final source = File(session.audioPath);
    if (!await source.exists()) return project;

    final sanitized = _safeFolderName(trimmed);
    if (sanitized.isEmpty) return project;
    var extension = session.audioPath.contains('.')
        ? session.audioPath.split('.').last.toLowerCase()
        : session.format.toLowerCase();
    if (extension.isEmpty || extension.length > 10) extension = 'm4a';

    final target = File(
        '${source.parent.path}/$sanitized-${session.id}.$extension');
    if (target.path == source.path) return project;

    try {
      if (await target.exists()) {
        final sameLength = await target.length() == await source.length();
        if (!sameLength) {
          await target.delete();
        } else {
          await source.delete();
          return project;
        }
      }
      final renamed = await source.rename(target.path);
      final sessions = List<RavenAudioSession>.of(project.sessions);
      sessions[index] = session.copyWith(audioPath: renamed.path);
      return project.copyWith(sessions: sessions);
    } on FileSystemException {
      // Leave the file where it is; the display name still updates.
      return project;
    }
  }

  Future<void> load() async {
    _projects.clear();
    await _loadCategories();
    final indexFile = File('${_rootDirectory.path}/projects.json');
    final backupFile = File('${_rootDirectory.path}/projects.json.bak');
    final temporaryFile = File('${_rootDirectory.path}/projects.json.tmp');

    for (final candidate in <File>[indexFile, backupFile, temporaryFile]) {
      if (!await candidate.exists()) continue;
      final recovered = await _tryReadProjects(candidate);
      if (recovered == null) continue;

      _projects
        ..clear()
        ..addAll(recovered)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      if (candidate.path != indexFile.path) {
        try {
          if (await indexFile.exists()) {
            final damagedCopy = File(
              '${_rootDirectory.path}/projects.json.corrupt-${DateTime.now().millisecondsSinceEpoch}',
            );
            await indexFile.copy(damagedCopy.path);
          }
          await candidate.copy(indexFile.path);
        } on FileSystemException {
          // Keep recovered projects available in memory even if repair is blocked.
        }
      }
      await _recoverInterruptedDrafts();
      await _includeProjectCategories();
      await _ensureProjectFolders();
      return;
    }
    await _includeProjectCategories();
    await _ensureProjectFolders();
  }

  Future<void> _ensureProjectFolders() async {
    for (final project in _projects) {
      if (project.isStandalone) continue;
      try {
        await ensureProjectFolder(project);
      } on FileSystemException {
        // A missing folder must never prevent the library from loading.
      }
    }
  }

  Future<void> _loadCategories() async {
    _categories
      ..clear()
      ..add('Uncategorized');
    final file = File('${_rootDirectory.path}/categories.json');
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        for (final category in decoded.whereType<String>()) {
          final clean = category.trim();
          if (clean.isNotEmpty &&
              !_categories.any((existing) =>
                  existing.toLowerCase() == clean.toLowerCase())) {
            _categories.add(clean);
          }
        }
      }
    } on FormatException {
      // Corrupt category file; rebuild from project records below.
    } on FileSystemException {
      // Unreadable category file; project records remain the source of truth.
    }
  }

  Future<void> _includeProjectCategories() async {
    var changed = false;
    for (final project in _projects) {
      final category = project.category.trim();
      if (category.isNotEmpty &&
          !_categories.any(
              (existing) => existing.toLowerCase() == category.toLowerCase())) {
        _categories.add(category);
        changed = true;
      }
    }
    if (changed ||
        !await File('${_rootDirectory.path}/categories.json').exists()) {
      await _saveCategories();
    }
  }

  Future<void> createCategory(String name) async {
    final category = name.trim();
    if (category.isEmpty || category.length > 60) {
      throw ArgumentError('Category names must contain 1 to 60 characters.');
    }
    if (_categories
        .any((existing) => existing.toLowerCase() == category.toLowerCase())) {
      throw StateError('A category with this name already exists.');
    }
    _categories.add(category);
    try {
      await _saveCategories();
    } catch (_) {
      _categories.remove(category);
      rethrow;
    }
  }

  Future<void> renameCategory(String currentName, String newName) async {
    if (currentName == 'Uncategorized') {
      throw StateError('The Uncategorized category cannot be renamed.');
    }
    final replacement = newName.trim();
    if (replacement.isEmpty || replacement.length > 60) {
      throw ArgumentError('Category names must contain 1 to 60 characters.');
    }
    if (replacement.toLowerCase() != currentName.toLowerCase() &&
        _categories.any((existing) =>
            existing.toLowerCase() == replacement.toLowerCase())) {
      throw StateError('A category with this name already exists.');
    }
    await _changeCategory(currentName, replacement);
  }

  Future<void> deleteCategory(String name) async {
    if (name == 'Uncategorized') {
      throw StateError('The Uncategorized category cannot be deleted.');
    }
    if (!_categories.contains(name)) return;
    await _changeCategory(name, 'Uncategorized', removeCategory: true);
  }

  Future<void> _changeCategory(
    String currentName,
    String replacement, {
    bool removeCategory = false,
  }) async {
    if (!_categories.contains(currentName)) {
      throw StateError('The selected category no longer exists.');
    }
    final originalCategories = List<String>.of(_categories);
    final originalProjects = List<RavenProject>.of(_projects);
    if (removeCategory) {
      _categories.remove(currentName);
    } else {
      _categories[_categories.indexOf(currentName)] = replacement;
    }
    for (var index = 0; index < _projects.length; index++) {
      if (_projects[index].category == currentName) {
        _projects[index] = _projects[index].copyWith(category: replacement);
      }
    }
    try {
      await saveAll();
      await _saveCategories();
      for (final project in _projects.where((item) =>
          item.category == replacement &&
          originalProjects.any(
              (old) => old.id == item.id && old.category == currentName))) {
        try {
          await _syncProjectManifest(project);
        } on FileSystemException {
          // Category manifests are derived indexes; the project record is canonical.
        }
      }
    } catch (_) {
      _categories
        ..clear()
        ..addAll(originalCategories);
      _projects
        ..clear()
        ..addAll(originalProjects);
      await saveAll();
      await _saveCategories();
      rethrow;
    }
  }

  Future<void> _saveCategories() async {
    final file = File('${_rootDirectory.path}/categories.json');
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temporary.writeAsString(jsonEncode(_categories), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.copy(backup.path);
    try {
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.copy(file.path);
      }
      rethrow;
    } finally {
      if (await backup.exists()) {
        try {
          await backup.delete();
        } on FileSystemException {
          // A stale backup is safe; the canonical category file is committed.
        }
      }
    }
  }

  Future<void> _recoverInterruptedDrafts() async {
    var changed = false;
    final recovery = WavRecoveryService();
    for (final project in List<RavenProject>.of(_projects)) {
      if (!project.isDraft) continue;
      final sessions = List<RavenAudioSession>.of(project.sessions);
      var projectChanged = false;
      for (var index = 0; index < sessions.length; index++) {
        final session = sessions[index];
        if (!session.recoverablePcm16) continue;
        int? durationMs;
        try {
          durationMs = await recovery.repairPcm16File(
            File(session.audioPath),
            sampleRate: session.sampleRate,
          );
        } on FileSystemException {
          // Keep the draft and source file intact for a later attempt.
          continue;
        }

        if (durationMs == null) continue;
        sessions[index] = session.copyWith(durationMs: durationMs);
        projectChanged = true;
      }
      if (projectChanged) {
        final recovered = project.copyWith(sessions: sessions);
        _projects[_projects.indexWhere((item) => item.id == project.id)] =
            recovered;
        changed = true;
      }
    }
    if (changed) await saveAll();
  }

  Future<List<RavenProject>?> _tryReadProjects(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return null;
      final projects = <RavenProject>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          projects.add(RavenProject.fromJson(Map<String, Object?>.from(item)));
        } on FormatException {
          // Isolate one malformed entry instead of losing the whole index.
        } on TypeError {
          // Isolate one malformed entry instead of losing the whole index.
        }
      }
      return projects;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> saveAll() async {
    final indexFile = File('${_rootDirectory.path}/projects.json');
    final temporaryFile = File('${_rootDirectory.path}/projects.json.tmp');
    final backupFile = File('${_rootDirectory.path}/projects.json.bak');
    await temporaryFile.writeAsString(
      jsonEncode(_projects.map((project) => project.toJson()).toList()),
      flush: true,
    );
    if (await indexFile.exists()) {
      await indexFile.copy(backupFile.path);
    }
    try {
      await temporaryFile.rename(indexFile.path);
    } catch (_) {
      if (!await indexFile.exists() && await backupFile.exists()) {
        await backupFile.copy(indexFile.path);
      }
      rethrow;
    }
    try {
      if (await backupFile.exists()) await backupFile.delete();
    } on FileSystemException {
      // A stale backup is harmless and is replaced on the next successful save.
    }
  }

  Future<void> add(RavenProject project) async {
    final existingIndex = _projects.indexWhere((item) => item.id == project.id);
    final previous = existingIndex < 0 ? null : _projects[existingIndex];
    if (existingIndex < 0) {
      _projects.add(project);
    } else {
      _projects[existingIndex] = project;
    }
    _projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    try {
      await saveAll();
      try {
        await _syncProjectManifest(project);
      } on FileSystemException {
        // Category manifests are derived indexes; rebuilt on next update.
      }
    } catch (_) {
      _projects.removeWhere((item) => item.id == project.id);
      if (previous != null) _projects.add(previous);
      _projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      rethrow;
    }
  }

  Future<void> update(RavenProject project) async {
    final existingIndex = _projects.indexWhere((item) => item.id == project.id);
    final previous = existingIndex < 0 ? null : _projects[existingIndex];
    if (existingIndex < 0) {
      _projects.add(project);
    } else {
      _projects[existingIndex] = project;
    }
    _projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    try {
      await saveAll();
      try {
        await _syncProjectManifest(project);
      } on FileSystemException {
        // Category manifests are derived indexes; rebuilt on next update.
      }
    } catch (_) {
      _projects.removeWhere((item) => item.id == project.id);
      if (previous != null) _projects.add(previous);
      _projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      rethrow;
    }
  }

  String _safeFolderName(String value) {
    final cleaned = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty
        ? 'Uncategorized'
        : cleaned.substring(0, cleaned.length > 60 ? 60 : cleaned.length);
  }

  Future<void> _syncProjectManifest(RavenProject project) async {
    final categoryDirectory = Directory(
        '${_rootDirectory.path}/categories/${_safeFolderName(project.category)}');
    await categoryDirectory.create(recursive: true);
    final manifest = File('${categoryDirectory.path}/${project.id}.json');
    final folderLocation = project.publicFolderLocation ??
        (project.isStandalone
            ? project.sessions.isEmpty
                ? recordingsDirectory.path
                : File(project.sessions.first.audioPath).parent.path
            : '${projectsDirectory.path}/${projectFolderName(project)}');
    await manifest.writeAsString(
        jsonEncode(<String, Object?>{
          'projectId': project.id,
          'title': project.title,
          'category': project.category,
          'updatedAt': project.updatedAt.toIso8601String(),
          'projectDirectory': project.isStandalone
              ? folderLocation
              : '${projectsDirectory.path}/${project.id}',
          'projectFolder': folderLocation,
          'isPublic': project.isPublic,
          'isPublicFolder': project.hasPublicFolder,
        }),
        flush: true);
    final categoriesRoot = Directory('${_rootDirectory.path}/categories');
    if (await categoriesRoot.exists()) {
      await for (final entity in categoriesRoot.list(followLinks: false)) {
        if (entity is! Directory || entity.path == categoryDirectory.path) {
          continue;
        }
        final stale = File('${entity.path}/${project.id}.json');
        if (await stale.exists()) await stale.delete();
      }
    }
  }

  Future<void> moveToTrash(RavenProject project) async {
    await update(project.copyWith(isTrashed: true, trashedAt: DateTime.now()));
  }

  Future<void> restore(RavenProject project) async {
    await update(project.copyWith(isTrashed: false, clearTrashedAt: true));
  }

  Future<void> purgeExpiredTrash({
    required int retentionDays,
    DateTime? now,
  }) async {
    if (retentionDays <= 0) return;
    final currentTime = now ?? DateTime.now();
    final expired = _projects.where((project) {
      return isTrashExpired(
        project,
        retentionDays: retentionDays,
        now: currentTime,
      );
    }).toList();
    for (final project in expired) {
      await deleteForever(project);
    }
  }

  static bool isTrashExpired(
    RavenProject project, {
    required int retentionDays,
    required DateTime now,
  }) {
    if (retentionDays <= 0 || !project.isTrashed) return false;
    final trashedAt = project.trashedAt;
    if (trashedAt == null) return false;
    return !trashedAt.add(Duration(days: retentionDays)).isAfter(now);
  }

  Future<void> deleteForever(RavenProject project) async {
    if (project.publicCopyLocation != null) {
      try {
        await AudioVisibilityService().remove(project.publicCopyLocation!);
      } on Exception {
        // Best-effort: a stale public copy must never block deleting the record.
      }
    }

    final existingIndex = _projects.indexWhere((item) => item.id == project.id);
    if (existingIndex < 0) return;
    final removed = _projects.removeAt(existingIndex);
    try {
      await saveAll();
    } catch (_) {
      _projects.insert(
          existingIndex.clamp(0, _projects.length).toInt(), removed);
      _projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      rethrow;
    }

    if (project.isStandalone) {
      final filesToDelete = <String>{
        for (final session in project.sessions) session.audioPath,
        if (project.masterAudioPath != null) project.masterAudioPath!,
        if (project.publicFolderLocation != null) project.publicFolderLocation!,
        if (project.publicCopyLocation != null) project.publicCopyLocation!,
      };
      for (final path in filesToDelete) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } on FileSystemException {
          // Best-effort: leftover files can be cleaned up manually.
        }
      }
    } else {
      final candidates = <Directory>{
        Directory('${projectsDirectory.path}/${project.id}'),
        Directory(
            '${projectsDirectory.path}/${projectFolderName(project)}'),
        if (project.publicFolderLocation != null)
          Directory(project.publicFolderLocation!),
      };
      for (final directory in candidates) {
        try {
          if (await directory.exists()) {
            await directory.delete(recursive: true);
          }
        } on FileSystemException {
          // Best-effort: a locked folder must not resurrect the removed record.
        }
      }
    }
  }
}