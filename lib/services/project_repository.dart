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

  Directory get projectsDirectory =>
      Directory('${_rootDirectory.path}/projects');

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

  /// Creates the on-device folder tree for a project. Every project owns a
  /// stable folder named after its title (with the ID appended so two projects
  /// with the same title never collide), containing the audio, notes,
  /// attachments, exports and metadata sub-folders.
  Future<Directory> ensureProjectFolder(RavenProject project) async {
    final folder = Directory('${projectsDirectory.path}/${projectFolderName(project)}');
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
    return folder;
  }

  /// Human-readable, filesystem-safe folder name for a project.
  String projectFolderName(RavenProject project) {
    final base = _safeFolderName(project.title);
    final shortId = project.id.length > 8
        ? project.id.substring(0, 8)
        : project.id;
    return '${base.isEmpty ? 'Project' : base}-$shortId';
  }

  Future<void> load() async {
    _projects.clear();
    await _loadCategories();
    final indexFile = File('${_rootDirectory.path}/projects.json');
    final backupFile = File('${_rootDirectory.path}/projects.json.bak');
    final temporaryFile = File('${_rootDirectory.path}/projects.json.tmp');

    // Try the primary index first, then the last known-good backup and the
    // write-in-progress file. A damaged index must not make every project vanish.
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

  /// Older projects were stored under their raw ID. Give every project the
  /// same on-device folder tree (audio, notes, attachments, exports, metadata)
  /// so the folder structure is consistent for new and existing projects.
  Future<void> _ensureProjectFolders() async {
    for (final project in _projects) {
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
      // Rebuild the category index from project records below.
    } on FileSystemException {
      // Project records remain the source of truth if the category file is unavailable.
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
          // Project records remain canonical; manifests are rebuilt on update.
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
          // Keep the draft and source file intact for a later recovery attempt.
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
          // Isolate one malformed entry instead of losing other projects.
        } on TypeError {
          // Isolate malformed legacy data.
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
      // Rename avoids exposing a partially written JSON index on supported filesystems.
      await temporaryFile.rename(indexFile.path);
    } catch (_) {
      // Preserve the previous index if replacing it fails on a platform/filesystem.
      if (!await indexFile.exists() && await backupFile.exists()) {
        await backupFile.copy(indexFile.path);
      }
      rethrow;
    }
    // Backup cleanup is housekeeping, not part of the durable write. If it
    // fails, keep the valid new index and the old backup for recovery.
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
      // Category manifests are derived indexes; a manifest write failure must
      // not roll back or hide the canonical project record.
      try {
        await _syncProjectManifest(project);
      } on FileSystemException {/* rebuilt on next update */}
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
      } on FileSystemException {/* rebuilt on next update */}
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
    await manifest.writeAsString(
        jsonEncode(<String, Object?>{
          'projectId': project.id,
          'title': project.title,
          'category': project.category,
          'updatedAt': project.updatedAt.toIso8601String(),
          'projectDirectory': '${projectsDirectory.path}/${project.id}',
          'projectFolder':
              '${projectsDirectory.path}/${projectFolderName(project)}',
          'isPublic': project.publicCopyLocation != null,
        }),
        flush: true);
    // Remove stale category pointers when a project moves; project files stay in
    // their stable ID directory so categorisation can never break audio paths.
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
    // Remove any RAVEN-managed public copy before permanently deleting its project.
    if (project.publicCopyLocation != null) {
      await AudioVisibilityService().remove(project.publicCopyLocation!);
    }
    final existingIndex = _projects.indexWhere((item) => item.id == project.id);
    if (existingIndex < 0) return;
    final removed = _projects.removeAt(existingIndex);
    try {
      // Remove the record from the durable index first. If this write fails,
      // roll back the in-memory list and leave the audio directory untouched.
      await saveAll();
    } catch (_) {
      _projects.insert(
          existingIndex.clamp(0, _projects.length).toInt(), removed);
      _projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      rethrow;
    }

    final directory = Directory('${projectsDirectory.path}/${project.id}');
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
