import 'dart:io';

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
    required this.onImportAudio,
    required this.onResumeProject,
    required this.onCreateCategory,
    required this.onRenameCategory,
    required this.onDeleteCategory,
    required this.onAssignCategory,
    required this.onCreateProject,
    required this.onShareProject,
    required this.onToggleVisibility,
    required this.onToggleProtection,
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
  final VoidCallback onImportAudio;
  final ValueChanged<RavenProject> onResumeProject;
  final Future<void> Function(String name) onCreateCategory;
  final Future<void> Function(String currentName, String newName)
      onRenameCategory;
  final Future<void> Function(String name) onDeleteCategory;
  final ValueChanged<RavenProject> onAssignCategory;
  final ValueChanged<RavenProject> onCreateProject;
  final ValueChanged<RavenProject> onShareProject;
  final Future<void> Function(RavenProject project) onToggleVisibility;
  final Future<void> Function(RavenProject project) onToggleProtection;

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
                    if (isCompact)
                      Builder(
                        builder: (context) => IconButton(
                          tooltip: tr(widget.preferences, 'Open library menu',
                              'Ouvrir le menu de la bibliothèque'),
                          onPressed: () => Scaffold.of(context).openDrawer(),
                          icon: const Icon(Icons.menu_rounded),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        _pageTitle,
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
                    PopupMenuButton<String>(
                      tooltip: tr(widget.preferences, 'Import audio or project',
                          'Importer un audio ou un projet'),
                      onSelected: (value) {
                        if (value == 'audio') {
                          widget.onImportAudio();
                        } else {
                          widget.onImportProject();
                        }
                      },
                      itemBuilder: (context) => <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'audio',
                          child: Text(tr(
                              widget.preferences,
                              'Import audio file',
                              'Importer un fichier audio')),
                        ),
                        PopupMenuItem<String>(
                          value: 'project',
                          child: Text(tr(
                              widget.preferences,
                              'Import RAVEN project bundle',
                              'Importer un projet RAVEN')),
                        ),
                      ],
                      icon: const Icon(Icons.file_upload_outlined),
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
                        onResume:
                            !project.isTrashed && !project.isAudioProtected
                                ? () => widget.onResumeProject(project)
                                : null,
                        onShare: project.isTrashed
                            ? null
                            : () => widget.onShareProject(project),
                        onToggleVisibility: project.isTrashed
                            ? null
                            : () => _toggleVisibility(project),
                        onToggleProtection: project.isTrashed
                            ? null
                            : () => widget.onToggleProtection(project),
                        onDetails: () => _showDetails(context, project),
                        onAssignCategory: project.isTrashed
                            ? null
                            : () => _chooseCategory(context, project),
                        onCreateProject: project.isStandalone &&
                                !project.isTrashed &&
                                !project.isAudioProtected
                            ? () => widget.onCreateProject(project)
                            : null,
                      );
                    },
                  ),
          );
          return Scaffold(
            drawer: isCompact
                ? Drawer(
                    child: SafeArea(
                      child: _LibrarySidebar(
                        preferences: widget.preferences,
                        categories: widget.categories,
                        projects: widget.projects,
                        filter: _filter,
                        selectedCategory: _selectedCategory,
                        closeOnSelect: true,
                        onFilter: (filter) => setState(() {
                          _filter = filter;
                          _selectedCategory = null;
                        }),
                        onCategory: (category) => setState(() {
                          _filter = LibraryFilter.all;
                          _selectedCategory = category;
                        }),
                        onManageCategories: () => _manageCategories(context),
                      ),
                    ),
                  )
                : null,
            body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 940),
                child: isCompact
                    ? Column(children: <Widget>[header, results])
                    : Row(
                        children: <Widget>[
                          SizedBox(
                            width: 240,
                            child: _LibrarySidebar(
                              preferences: widget.preferences,
                              categories: widget.categories,
                              projects: widget.projects,
                              filter: _filter,
                              selectedCategory: _selectedCategory,
                              closeOnSelect: false,
                              onFilter: (filter) => setState(() {
                                _filter = filter;
                                _selectedCategory = null;
                              }),
                              onCategory: (category) => setState(() {
                                _filter = LibraryFilter.all;
                                _selectedCategory = category;
                              }),
                              onManageCategories: () =>
                                  _manageCategories(context),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: Column(
                              children: <Widget>[
                                header,
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 28),
                                  child: filterChips,
                                ),
                                results,
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  String get _pageTitle {
    if (_filter == LibraryFilter.trash) {
      return tr(widget.preferences, 'Trash', 'Corbeille');
    }
    if (_filter == LibraryFilter.favorites) {
      return tr(widget.preferences, 'Favourites', 'Favoris');
    }
    return _selectedCategory ??
        tr(widget.preferences, 'All recordings', 'Tous les enregistrements');
  }

  Future<void> _showDetails(BuildContext context, RavenProject project) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final paths = <String>{
        ...project.sessions.map((session) => session.audioPath),
        if (project.masterAudioPath != null) project.masterAudioPath!,
      };
      var totalBytes = 0;
      for (final path in paths) {
        final file = File(path);
        if (await file.exists()) totalBytes += await file.length();
      }

      if (!context.mounted) return;
      final formats = project.sessions
          .map((session) => session.format.toUpperCase())
          .toSet()
          .join(', ');
      final locale = widget.preferences.isFrench ? 'fr' : 'en';
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(widget.preferences, 'Recording details',
              'Détails de l’enregistrement')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _detailRow(
                    widget.preferences,
                    'Created',
                    DateFormat('dd MMM yyyy · HH:mm', locale)
                        .format(project.createdAt)),
                _detailRow(
                    widget.preferences,
                    'Last updated',
                    DateFormat('dd MMM yyyy · HH:mm', locale)
                        .format(project.updatedAt)),
                _detailRow(widget.preferences, 'Duration',
                    _formatDuration(project.durationMs)),
                _detailRow(widget.preferences, 'Storage used',
                    _formatBytes(totalBytes)),
                _detailRow(widget.preferences, 'Recording sessions',
                    '${project.sessions.length}'),
                _detailRow(widget.preferences, 'Audio format',
                    formats.isEmpty ? '—' : formats),
                if (project.sessions.isNotEmpty)
                  _detailRow(
                    widget.preferences,
                    'Sample rate',
                    '${(project.sessions.last.sampleRate / 1000).toStringAsFixed(1)} kHz',
                  ),
                _detailRow(widget.preferences, 'Category', project.category),
                _detailRow(
                    widget.preferences,
                    'Privacy',
                    project.publicCopyLocation == null
                        ? tr(widget.preferences, 'Private in RAVEN',
                            'Privé dans RAVEN')
                        : tr(widget.preferences, 'Has a device-folder copy',
                            'Possède une copie dans les dossiers')),
                if (project.isAudioProtected)
                  _detailRow(widget.preferences, 'Encryption', 'Encrypted'),
                if (project.requiresAppPin)
                  _detailRow(
                      widget.preferences, 'Access lock', 'RAVEN PIN required'),
                if (project.isDraft)
                  _detailRow(widget.preferences, 'Status', 'Recovered draft'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr(widget.preferences, 'Done', 'Terminé')),
            ),
          ],
        ),
      );
    } catch (error) {
      if (context.mounted) {
        messenger.showSnackBar(SnackBar(
            content: Text(
                '${tr(widget.preferences, 'Could not load recording details', 'Impossible de charger les détails')}: $error')));
      }
    }
  }

  Future<void> _toggleVisibility(RavenProject project) async {
    try {
      await widget.onToggleVisibility(project);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not update recording visibility: $error'),
      ));
    }
  }

  Future<void> _chooseCategory(
      BuildContext context, RavenProject project) async {
    final category = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr(widget.preferences, 'Move to category',
            'Déplacer vers une catégorie')),
        children: widget.categories
            .map((name) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, name),
                  child: Row(
                    children: <Widget>[
                      Icon(name == project.category
                          ? Icons.check_circle_rounded
                          : Icons.folder_outlined),
                      const SizedBox(width: 12),
                      Text(name),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (category != null && category != project.category) {
      widget.onAssignCategory(project.copyWith(category: category));
    }
  }

  Widget _detailRow(AppPreferences preferences, String label, String value) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 130,
              child: Text(tr(preferences, label, _frenchDetailLabel(label)),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  String _frenchDetailLabel(String label) => switch (label) {
        'Created' => 'Créé',
        'Last updated' => 'Modifié',
        'Duration' => 'Durée',
        'Storage used' => 'Espace utilisé',
        'Recording sessions' => 'Sessions',
        'Audio format' => 'Format audio',
        'Category' => 'Catégorie',
        'Privacy' => 'Confidentialité',
        'Encryption' => 'Chiffrement',
        'Sample rate' => 'Fréquence',
        'Access lock' => 'Verrou d’accès',
        'Status' => 'État',
        _ => label,
      };

  String _formatDuration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0
        ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
    this.onDetails,
    this.onAssignCategory,
    this.onCreateProject,
    this.onShare,
    this.onToggleVisibility,
    this.onToggleProtection,
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
  final VoidCallback? onDetails;
  final VoidCallback? onAssignCategory;
  final VoidCallback? onCreateProject;
  final VoidCallback? onShare;
  final VoidCallback? onToggleVisibility;
  final VoidCallback? onToggleProtection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = project.title.trim().isEmpty
        ? tr(preferences, 'Untitled recording', 'Enregistrement sans titre')
        : project.title;
    final date =
        DateFormat('dd MMM yyyy · HH:mm', preferences.isFrench ? 'fr' : 'en')
            .format(project.createdAt);
    final trashedDate =
        DateFormat('dd MMM yyyy · HH:mm', preferences.isFrench ? 'fr' : 'en')
            .format(project.trashedAt ?? project.updatedAt);
    final duration = _formatDuration(project.durationMs);
    final subtitle = project.isTrashed
        ? preferences.trashRetentionDays == 0
            ? tr(preferences, 'In Trash since $trashedDate · Never expires',
                'Dans la corbeille depuis le $trashedDate · N’expire jamais')
            : tr(
                preferences,
                'In Trash since $trashedDate · Expires ${DateFormat('dd MMM yyyy', preferences.isFrench ? 'fr' : 'en').format((project.trashedAt ?? project.updatedAt).add(Duration(days: preferences.trashRetentionDays)))}',
                'Dans la corbeille depuis le $trashedDate · Expire le ${DateFormat('dd MMM yyyy', preferences.isFrench ? 'fr' : 'en').format((project.trashedAt ?? project.updatedAt).add(Duration(days: preferences.trashRetentionDays)))}',
              )
        : project.isDraft
            ? '$date  ·  ${tr(preferences, 'Interrupted draft — review audio', 'Brouillon interrompu — vérifier l’audio')}'
            : '$date  ·  $duration';
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
                      subtitle,
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
                  onDetails != null ||
                  onAssignCategory != null ||
                  onCreateProject != null ||
                  onShare != null ||
                  onToggleVisibility != null ||
                  onToggleProtection != null ||
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
                      case 'details':
                        onDetails?.call();
                        break;
                      case 'category':
                        onAssignCategory?.call();
                        break;
                      case 'create_project':
                        onCreateProject?.call();
                        break;
                      case 'share':
                        onShare?.call();
                        break;
                      case 'visibility':
                        onToggleVisibility?.call();
                        break;
                      case 'protection':
                        onToggleProtection?.call();
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
                    if (onDetails != null)
                      PopupMenuItem(
                        value: 'details',
                        child: Text(tr(preferences, 'Details', 'Détails')),
                      ),
                    if (!project.isTrashed && onAssignCategory != null)
                      PopupMenuItem(
                        value: 'category',
                        child: Text(tr(preferences, 'Move to category',
                            'Déplacer vers une catégorie')),
                      ),
                    if (onCreateProject != null)
                      PopupMenuItem(
                        value: 'create_project',
                        child: Text(tr(
                            preferences, 'Create project', 'Créer un projet')),
                      ),
                    if (onShare != null)
                      PopupMenuItem(
                        value: 'share',
                        child: Text(
                            tr(preferences, 'Share audio', 'Partager l’audio')),
                      ),
                    if (onToggleVisibility != null)
                      PopupMenuItem(
                        value: 'visibility',
                        child: Text(tr(
                          preferences,
                          project.publicCopyLocation == null
                              ? 'Make public'
                              : 'Make private',
                          project.publicCopyLocation == null
                              ? 'Rendre public'
                              : 'Rendre privé',
                        )),
                      ),
                    if (onToggleProtection != null)
                      PopupMenuItem(
                        value: 'protection',
                        child: Text(tr(
                          preferences,
                          project.isAudioProtected
                              ? 'Unlock audio'
                              : 'Lock audio with a password',
                          project.isAudioProtected
                              ? 'Déverrouiller l’audio'
                              : 'Verrouiller l’audio avec un mot de passe',
                        )),
                      ),
                    if (onResume != null)
                      PopupMenuItem(
                        value: 'resume',
                        child: Text(
                          project.isStandalone
                              ? tr(preferences, 'Resume recording',
                                  'Reprendre l’enregistrement')
                              : tr(preferences, 'Add another session',
                                  'Ajouter une session'),
                        ),
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
                    if (onDelete != null)
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
    required this.projects,
    required this.filter,
    required this.selectedCategory,
    required this.closeOnSelect,
    required this.onFilter,
    required this.onCategory,
    required this.onManageCategories,
  });

  final AppPreferences preferences;
  final List<String> categories;
  final List<RavenProject> projects;
  final LibraryFilter filter;
  final String? selectedCategory;
  final bool closeOnSelect;
  final ValueChanged<LibraryFilter> onFilter;
  final ValueChanged<String> onCategory;
  final VoidCallback onManageCategories;

  int _count(bool Function(RavenProject) predicate) =>
      projects.where(predicate).length;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 20, 10, 24),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 14),
          child: Row(
            children: <Widget>[
              Image.asset(
                'assets/images/raven_logo.png',
                width: 34,
                height: 34,
                errorBuilder: (_, __, ___) => Icon(Icons.graphic_eq_rounded,
                    color: colorScheme.primary, size: 30),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'RAVEN',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 2),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
          child: Text(
            tr(preferences, 'Browse', 'Parcourir'),
            style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1),
          ),
        ),
        _sidebarItem(
          context,
          icon: Icons.library_music_outlined,
          title: tr(preferences, 'All recordings', 'Tous les enregistrements'),
          count: _count((project) => !project.isTrashed),
          selected: filter == LibraryFilter.all && selectedCategory == null,
          onTap: () => onFilter(LibraryFilter.all),
        ),
        _sidebarItem(
          context,
          icon: Icons.star_outline_rounded,
          title: tr(preferences, 'Favourites', 'Favoris'),
          count: _count((project) => !project.isTrashed && project.isFavorite),
          selected: filter == LibraryFilter.favorites,
          onTap: () => onFilter(LibraryFilter.favorites),
        ),
        _sidebarItem(
          context,
          icon: Icons.delete_outline_rounded,
          title: tr(preferences, 'Trash', 'Corbeille'),
          count: _count((project) => project.isTrashed),
          selected: filter == LibraryFilter.trash,
          onTap: () => onFilter(LibraryFilter.trash),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 8, 6),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  tr(preferences, 'Categories', 'Catégories'),
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1),
                ),
              ),
              IconButton(
                tooltip: tr(preferences, 'Manage categories',
                    'Gérer les catégories'),
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onManageCategories,
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
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
            count: _count((project) =>
                !project.isTrashed && project.category == category),
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
    required int count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? colorScheme.primaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            onTap();
            if (closeOnSelect) Scaffold.of(context).closeDrawer();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: selected
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: colorScheme.primary.withValues(alpha: 0.4)),
                  )
                : null,
            child: Row(
              children: <Widget>[
                Icon(
                  icon,
                  size: 20,
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? colorScheme.primary
                          : colorScheme.onSurface,
                    ),
                  ),
                ),
                if (count > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: selected
                          ? colorScheme.primary.withValues(alpha: 0.15)
                          : colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
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
