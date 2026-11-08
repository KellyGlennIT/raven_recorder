import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';

enum LibraryFilter { all, favorites, trash }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.projects,
    required this.categories,
    required this.preferences,
    required this.onOpenProject,
    required this.onFavorite,
    required this.onRename,
    required this.onTrash,
    required this.onRestore,
    required this.onDelete,
    required this.onImportProject,
    required this.onResumeProject,
    required this.onCreateCategory,
    required this.onRenameCategory,
    required this.onDeleteCategory,
    super.key,
  });

  final List<RavenProject> projects;
  final List<String> categories;
  final AppPreferences preferences;
  final ValueChanged<RavenProject> onOpenProject;
  final ValueChanged<RavenProject> onFavorite;
  final ValueChanged<RavenProject> onRename;
  final ValueChanged<RavenProject> onTrash;
  final ValueChanged<RavenProject> onRestore;
  final ValueChanged<RavenProject> onDelete;
  final VoidCallback onImportProject;
  final ValueChanged<RavenProject> onResumeProject;
  final Future<void> Function(String name) onCreateCategory;
  final Future<void> Function(String currentName, String newName)
      onRenameCategory;
  final Future<void> Function(String name) onDeleteCategory;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  LibraryFilter _filter = LibraryFilter.all;
  String? _selectedCategory;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _searchController.text.trim().toLowerCase();
    final visible = widget.projects.where((project) {
      final matchesFilter = switch (_filter) {
        LibraryFilter.all => !project.isTrashed,
        LibraryFilter.favorites => !project.isTrashed && project.isFavorite,
        LibraryFilter.trash => project.isTrashed,
      };
      if (!matchesFilter) return false;
      if (_selectedCategory != null && project.category != _selectedCategory) {
        return false;
      }
      return project.title.toLowerCase().contains(query) ||
          project.category.toLowerCase().contains(query) ||
          project.tags.any((tag) => tag.toLowerCase().contains(query));
    }).toList();

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 740;
          final horizontalPadding = isCompact ? 16.0 : 28.0;
          final filterChips = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                _FilterChip(
                  label: tr(widget.preferences, 'All', 'Tous'),
                  selected: _filter == LibraryFilter.all,
                  onTap: () => setState(() => _filter = LibraryFilter.all),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: tr(widget.preferences, 'Favourites', 'Favoris'),
                  selected: _filter == LibraryFilter.favorites,
                  onTap: () =>
                      setState(() => _filter = LibraryFilter.favorites),
                ),
                const SizedBox(width: 8),
                _FilterChip(
                  label: tr(widget.preferences, 'Trash', 'Corbeille'),
                  selected: _filter == LibraryFilter.trash,
                  onTap: () => setState(() => _filter = LibraryFilter.trash),
                ),
              ],
            ),
          );
          final header = Padding(
            padding: EdgeInsets.fromLTRB(
                horizontalPadding, isCompact ? 16 : 28, horizontalPadding, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        tr(widget.preferences, 'Library', 'Bibliothèque'),
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: tr(widget.preferences, 'Manage categories',
                          'Gérer les catégories'),
                      onPressed: () => _manageCategories(context),
                      icon: const Icon(Icons.folder_copy_outlined),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      tooltip: tr(
                          widget.preferences,
                          'Import RAVEN project bundle',
                          'Importer un projet RAVEN'),
                      onPressed: widget.onImportProject,
                      icon: const Icon(Icons.archive_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  tr(
                      widget.preferences,
                      'Browse projects, standalone recordings and recovered drafts.',
                      'Parcourez les projets, les enregistrements autonomes et les brouillons récupérés.'),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 17),
                TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: tr(
                        widget.preferences,
                        'Search title, category or tag',
                        'Rechercher titre, catégorie ou étiquette'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                          ),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                if (isCompact) ...<Widget>[
                  const SizedBox(height: 13),
                  filterChips,
                  const SizedBox(height: 9),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        _FilterChip(
                          label: tr(widget.preferences, 'All categories',
                              'Toutes les catégories'),
                          selected: _selectedCategory == null,
                          onTap: () => setState(() => _selectedCategory = null),
                        ),
                        for (final category in widget.categories) ...<Widget>[
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: category,
                            selected: _selectedCategory == category,
                            onTap: () => setState(
                              () => _selectedCategory = category,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
          final results = Expanded(
            child: visible.isEmpty
                ? _EmptyLibrary(
                    preferences: widget.preferences, filter: _filter)
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 8, horizontalPadding, 24),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final project = visible[index];
                      return ProjectTile(
                        project: project,
                        preferences: widget.preferences,
                        onTap: () => widget.onOpenProject(project),
                        onFavorite: () => widget.onFavorite(project),
                        onRename: () => _rename(context, project),
                        onTrash: () => _confirmTrash(context, project),
                        onRestore: () => widget.onRestore(project),
                        onDelete: () => _confirmDelete(context, project),
                        onResume: project.isStandalone &&
                                !project.isTrashed &&
                                !project.isAudioProtected
                            ? () => widget.onResumeProject(project)
                            : null,
                      );
                    },
                  ),
          );
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: isCompact
                  ? Column(children: <Widget>[header, results])
                  : Row(
                      children: <Widget>[
                        SizedBox(
                          width: 205,
                          child: _LibrarySidebar(
                            preferences: widget.preferences,
                            categories: widget.categories,
                            filter: _filter,
                            selectedCategory: _selectedCategory,
                            onFilter: (filter) => setState(() {
                              _filter = filter;
                              _selectedCategory = null;
                            }),
                            onCategory: (category) => setState(() {
                              _filter = LibraryFilter.all;
                              _selectedCategory = category;
                            }),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: Column(
                            children: <Widget>[
                              header,
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 28),
                                child: filterChips,
                              ),
                              results,
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _rename(BuildContext context, RavenProject project) async {
    final controller = TextEditingController(text: project.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
            tr(widget.preferences, 'Rename project', 'Renommer le projet')),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
              labelText:
                  tr(widget.preferences, 'Project title', 'Titre du projet')),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: Text(tr(widget.preferences, 'Save', 'Enregistrer'))),
        ],
      ),
    );
    controller.dispose();
    if (title != null &&
        title.trim().isNotEmpty &&
        title.trim() != project.title) {
      widget.onRename(project.copyWith(title: title.trim()));
    }
  }

  Future<void> _manageCategories(BuildContext context) async {
    final controller = TextEditingController();
    String? error;
    late StateSetter setDialogState;

    Future<void> createCategory() async {
      try {
        await widget.onCreateCategory(controller.text);
        controller.clear();
        setDialogState(() => error = null);
      } catch (failure) {
        setDialogState(() => error = failure.toString());
      }
    }

    Future<void> renameCategory(String category) async {
      final nameController = TextEditingController(text: category);
      final replacement = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(
              widget.preferences, 'Rename category', 'Renommer la catégorie')),
          content: TextField(
            controller: nameController,
            autofocus: true,
            maxLength: 60,
            onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
            decoration: InputDecoration(
              labelText: tr(widget.preferences, 'Category name', 'Nom'),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, nameController.text.trim()),
              child: Text(tr(widget.preferences, 'Save', 'Enregistrer')),
            ),
          ],
        ),
      );
      nameController.dispose();
      if (replacement == null || replacement.trim().isEmpty) return;
      try {
        await widget.onRenameCategory(category, replacement);
        if (_selectedCategory == category) {
          setState(() => _selectedCategory = replacement);
        }
        setDialogState(() => error = null);
      } catch (failure) {
        setDialogState(() => error = failure.toString());
      }
    }

    Future<void> removeCategory(String category) async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(widget.preferences, 'Delete category?',
              'Supprimer la catégorie ?')),
          content: Text(tr(
            widget.preferences,
            'Recordings in this category will move to Uncategorized.',
            'Les enregistrements de cette catégorie seront déplacés dans « Non classé ». ',
          )),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(widget.preferences, 'Delete', 'Supprimer')),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        await widget.onDeleteCategory(category);
        if (_selectedCategory == category) {
          setState(() => _selectedCategory = null);
        }
        setDialogState(() => error = null);
      } catch (failure) {
        setDialogState(() => error = failure.toString());
      }
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogState) {
          setDialogState = dialogState;
          return AlertDialog(
            title: Text(tr(widget.preferences, 'Manage categories',
                'Gérer les catégories')),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: controller,
                          maxLength: 60,
                          decoration: InputDecoration(
                            labelText: tr(widget.preferences, 'New category',
                                'Nouvelle catégorie'),
                          ),
                          onSubmitted: (_) => createCategory(),
                        ),
                      ),
                      IconButton(
                        tooltip:
                            tr(widget.preferences, 'Add category', 'Ajouter'),
                        onPressed: createCategory,
                        icon: const Icon(Icons.add_circle_outline_rounded),
                      ),
                    ],
                  ),
                  if (error != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 240,
                    child: ListView(
                      shrinkWrap: true,
                      children: widget.categories
                          .where((category) => category != 'Uncategorized')
                          .map(
                            (category) => ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(category),
                              trailing: Wrap(
                                children: <Widget>[
                                  IconButton(
                                    tooltip: tr(widget.preferences, 'Rename',
                                        'Renommer'),
                                    onPressed: () => renameCategory(category),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: tr(widget.preferences, 'Delete',
                                        'Supprimer'),
                                    onPressed: () => removeCategory(category),
                                    icon: const Icon(
                                        Icons.delete_outline_rounded),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(tr(widget.preferences, 'Done', 'Terminé')),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }

  Future<void> _confirmTrash(BuildContext context, RavenProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Move to trash?',
            'Déplacer vers la corbeille ?')),
        content: Text(tr(
            widget.preferences,
            'You can restore this project later.',
            'Vous pourrez restaurer ce projet plus tard.')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(widget.preferences, 'Move to trash',
                  'Mettre à la corbeille'))),
        ],
      ),
    );
    if (confirmed == true) widget.onTrash(project);
  }

  Future<void> _confirmDelete(
      BuildContext context, RavenProject project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(widget.preferences, 'Delete permanently?',
            'Supprimer définitivement ?')),
        content: Text(tr(
            widget.preferences,
            'This removes the project and its audio from this device.',
            'Cela supprime le projet et son audio de cet appareil. Cette action est irréversible.')),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(widget.preferences, 'Cancel', 'Annuler'))),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(widget.preferences, 'Delete permanently',
                  'Supprimer définitivement'))),
        ],
      ),
    );
    if (confirmed == true) widget.onDelete(project);
  }
}

class ProjectTile extends StatelessWidget {
  const ProjectTile({
    required this.project,
    required this.preferences,
    required this.onTap,
    this.onFavorite,
    this.onRename,
    this.onTrash,
    this.onRestore,
    this.onDelete,
    this.onResume,
    super.key,
  });

  final RavenProject project;
  final AppPreferences preferences;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final VoidCallback? onRename;
  final VoidCallback? onTrash;
  final VoidCallback? onRestore;
  final VoidCallback? onDelete;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = project.title.trim().isEmpty
        ? tr(preferences, 'Untitled recording', 'Enregistrement sans titre')
        : project.title;
    final date =
        DateFormat('dd MMM yyyy · HH:mm', preferences.isFrench ? 'fr' : 'en')
            .format(project.createdAt);
    final duration = _formatDuration(project.durationMs);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 7, 14),
          child: Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(15)),
                child: Icon(
                    project.isTrashed
                        ? Icons.delete_outline_rounded
                        : project.isStandalone
                            ? Icons.mic_none_rounded
                            : Icons.audio_file_outlined,
                    color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 5),
                    Text(
                      project.isDraft
                          ? '$date  ·  ${tr(preferences, 'Interrupted draft — review audio', 'Brouillon interrompu — vérifier l’audio')}'
                          : '$date  ·  $duration',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: project.isDraft
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (project.category != 'Uncategorized') ...<Widget>[
                      const SizedBox(height: 6),
                      Text(project.category,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: theme.colorScheme.primary)),
                    ],
                  ],
                ),
              ),
              if (!project.isTrashed && onFavorite != null)
                IconButton(
                  tooltip: project.isFavorite
                      ? tr(preferences, 'Remove favourite',
                          'Retirer des favoris')
                      : tr(preferences, 'Add favourite', 'Ajouter aux favoris'),
                  onPressed: onFavorite,
                  icon: Icon(
                      project.isFavorite
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      color: project.isFavorite
                          ? theme.colorScheme.tertiary
                          : null),
                ),
              if (onResume != null ||
                  onRename != null ||
                  onTrash != null ||
                  onRestore != null ||
                  onDelete != null)
                PopupMenuButton<String>(
                  tooltip:
                      tr(preferences, 'Project actions', 'Actions du projet'),
                  onSelected: (action) {
                    switch (action) {
                      case 'rename':
                        onRename?.call();
                        break;
                      case 'resume':
                        onResume?.call();
                        break;
                      case 'trash':
                        onTrash?.call();
                        break;
                      case 'restore':
                        onRestore?.call();
                        break;
                      case 'delete':
                        onDelete?.call();
                        break;
                    }
                  },
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    if (onResume != null)
                      PopupMenuItem(
                        value: 'resume',
                        child: Text(tr(preferences, 'Resume recording',
                            'Reprendre l’enregistrement')),
                      ),
                    if (!project.isTrashed && onRename != null)
                      PopupMenuItem(
                          value: 'rename',
                          child: Text(tr(preferences, 'Rename', 'Renommer'))),
                    if (!project.isTrashed && onTrash != null)
                      PopupMenuItem(
                          value: 'trash',
                          child: Text(tr(preferences, 'Move to trash',
                              'Mettre à la corbeille'))),
                    if (project.isTrashed && onRestore != null)
                      PopupMenuItem(
                          value: 'restore',
                          child: Text(tr(preferences, 'Restore', 'Restaurer'))),
                    if (project.isTrashed && onDelete != null)
                      PopupMenuItem(
                          value: 'delete',
                          child: Text(tr(preferences, 'Delete permanently',
                              'Supprimer définitivement'))),
                  ],
                )
              else
                const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(int milliseconds) {
    final d = Duration(milliseconds: milliseconds);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours.toString().padLeft(2, '0')}:$m:$s';
    return '$m:$s';
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
      label: Text(label), selected: selected, onSelected: (_) => onTap());
}

class _LibrarySidebar extends StatelessWidget {
  const _LibrarySidebar({
    required this.preferences,
    required this.categories,
    required this.filter,
    required this.selectedCategory,
    required this.onFilter,
    required this.onCategory,
  });

  final AppPreferences preferences;
  final List<String> categories;
  final LibraryFilter filter;
  final String? selectedCategory;
  final ValueChanged<LibraryFilter> onFilter;
  final ValueChanged<String> onCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 24, 8, 24),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
          child: Text(
            tr(preferences, 'Browse', 'Parcourir'),
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        _sidebarItem(
          context,
          icon: Icons.library_music_outlined,
          title: tr(preferences, 'All recordings', 'Tous les enregistrements'),
          selected: filter == LibraryFilter.all && selectedCategory == null,
          onTap: () => onFilter(LibraryFilter.all),
        ),
        _sidebarItem(
          context,
          icon: Icons.star_outline_rounded,
          title: tr(preferences, 'Favourites', 'Favoris'),
          selected: filter == LibraryFilter.favorites,
          onTap: () => onFilter(LibraryFilter.favorites),
        ),
        _sidebarItem(
          context,
          icon: Icons.delete_outline_rounded,
          title: tr(preferences, 'Trash', 'Corbeille'),
          selected: filter == LibraryFilter.trash,
          onTap: () => onFilter(LibraryFilter.trash),
        ),
        const Divider(height: 28),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
          child: Text(
            tr(preferences, 'Categories', 'Catégories'),
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final category in categories)
          _sidebarItem(
            context,
            icon: category == 'Uncategorized'
                ? Icons.folder_open_outlined
                : Icons.folder_outlined,
            title: category == 'Uncategorized'
                ? tr(preferences, 'Uncategorized', 'Non classé')
                : category,
            selected: selectedCategory == category,
            onTap: () => onCategory(category),
          ),
      ],
    );
  }

  Widget _sidebarItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(icon, size: 20),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onTap: onTap,
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.preferences, required this.filter});
  final AppPreferences preferences;
  final LibraryFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, subtitle) = switch (filter) {
      LibraryFilter.all => (
          Icons.audio_file_outlined,
          tr(preferences, 'No projects yet', 'Aucun projet pour le moment'),
          tr(preferences, 'Start a recording and it will appear here.',
              'Démarrez un enregistrement pour le voir ici.')
        ),
      LibraryFilter.favorites => (
          Icons.star_border_rounded,
          tr(preferences, 'No favourites yet', 'Aucun favori'),
          tr(preferences, 'Mark important projects with the star.',
              'Marquez les projets importants avec l’étoile.')
        ),
      LibraryFilter.trash => (
          Icons.delete_outline_rounded,
          tr(preferences, 'Trash is empty', 'La corbeille est vide'),
          tr(preferences, 'Deleted projects can be restored here.',
              'Les projets supprimés peuvent être restaurés ici.')
        ),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(title,
                style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 7),
            Text(subtitle,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
