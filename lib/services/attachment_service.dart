import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'project_repository.dart';

/// Imports user-selected documents/images into a project's private attachment
/// directory. File names are sanitized and collisions receive a unique suffix.
class AttachmentService {
  const AttachmentService(this._repository);
  final ProjectRepository _repository;

  Future<List<File>> pickAndAttach(String projectId) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return <File>[];

    final target = Directory('${_repository.projectsDirectory.path}/$projectId/attachments');
    await target.create(recursive: true);
    final copied = <File>[];
    for (final selected in result.files) {
      final sourcePath = selected.path;
      if (sourcePath == null || sourcePath.isEmpty) continue;
      final source = File(sourcePath);
      if (!await source.exists()) continue;
      final safeName = _safeName(p.basename(source.path));
      final destination = await _uniqueDestination(target, safeName);
      await source.copy(destination.path);
      copied.add(destination);
    }
    return copied;
  }

  Future<List<File>> list(String projectId) async {
    final directory = Directory('${_repository.projectsDirectory.path}/$projectId/attachments');
    if (!await directory.exists()) return <File>[];
    final result = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) result.add(entity);
    }
    result.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
    return result;
  }

  Future<void> remove(File attachment) async {
    if (await attachment.exists()) await attachment.delete();
  }

  Future<File> _uniqueDestination(Directory directory, String name) async {
    var destination = File(p.join(directory.path, name));
    if (!await destination.exists()) return destination;
    final extension = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    for (var i = 2; i < 10000; i++) {
      destination = File(p.join(directory.path, '$stem ($i)$extension'));
      if (!await destination.exists()) return destination;
    }
    throw FileSystemException('Too many files with the same name.', name);
  }

  String _safeName(String name) {
    final safe = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (safe.isEmpty || safe == '.' || safe == '..') return 'attachment';
    return safe.length > 120 ? safe.substring(0, 120) : safe;
  }
}
