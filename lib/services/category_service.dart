import 'project_repository.dart';

/// Category operations update project metadata only. Audio remains in its
/// stable project-ID directory, so renaming/deleting a category cannot orphan it.
class CategoryService {
  const CategoryService(this._repository);
  final ProjectRepository _repository;

  List<String> listCategories({bool includeTrashed = false}) {
    final names = <String>{'Uncategorized'};
    for (final project in _repository.projects) {
      if (!includeTrashed && project.isTrashed) continue;
      final category = project.category.trim();
      if (category.isNotEmpty) names.add(category);
    }
    final result = names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  Future<void> renameCategory(String oldName, String newName) async {
    final oldCategory = oldName.trim();
    final newCategory = _validate(newName);
    if (oldCategory.isEmpty) throw ArgumentError.value(oldName, 'oldName');
    if (oldCategory.toLowerCase() == newCategory.toLowerCase()) return;
    if (listCategories().any((name) => name.toLowerCase() == newCategory.toLowerCase())) {
      throw StateError('A category with that name already exists.');
    }
    final affected = _repository.projects.where((project) => project.category == oldCategory).toList();
    for (final project in affected) {
      await _repository.update(project.copyWith(category: newCategory));
    }
  }

  Future<void> deleteCategory(String name, {String moveProjectsTo = 'Uncategorized'}) async {
    final category = name.trim();
    if (category.isEmpty || category.toLowerCase() == 'uncategorized') {
      throw ArgumentError('The Uncategorized category cannot be deleted.');
    }
    final destination = _validate(moveProjectsTo);
    if (destination.toLowerCase() == category.toLowerCase()) {
      throw ArgumentError('Choose a different destination category.');
    }
    final affected = _repository.projects.where((project) => project.category == category).toList();
    for (final project in affected) {
      await _repository.update(project.copyWith(category: destination));
    }
  }

  String _validate(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) throw ArgumentError('Category name cannot be empty.');
    if (normalized.length > 48) throw ArgumentError('Category name must be 48 characters or fewer.');
    if (RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(normalized)) {
      throw ArgumentError('Category name contains unsupported characters.');
    }
    return normalized;
  }
}
