import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    this.onShareProjects,
    this.onTogglePin,
    super.key,
  });

  final List<RavenProject> projects;
  final List<String> categories;
  final AppPreferences preferences;

  final Future<void> Function(RavenProject) onOpenProject;
  final Future<void> Function(RavenProject) onFavorite;
  final Future<void> Function(RavenProject) onRename;
  final Future<void> Function(RavenProject) onTrash;
  final Future<void> Function(RavenProject) onRestore;
  final Future<void> Function(RavenProject) onDelete;
  final Future<void> Function(RavenProject) onResumeProject;
  final Future<void> Function(RavenProject) onAssignCategory;
  final Future<void> Function(RavenProject) onCreateProject;
  final Future<void> Function(RavenProject) onShareProject;

  final VoidCallback onImportProject;
  final VoidCallback onImportAudio;
  final Future<void> Function(String name) onCreateCategory;
  final Future<void> Function(String currentName, String newName)
      onRenameCategory;
  final Future<void> Function(String name) onDeleteCategory;
  final Future<void> Function(RavenProject project) onToggleVisibility;
  final Future<void> Function(RavenProject project) onToggleProtection;

  final Future<void> Function(List<RavenProject> projects)? onShareProjects;
  final Future<void> Function(RavenProject project)? onTogglePin;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedIds = <String>{};
  LibraryFilter _filter = LibraryFilter.all;
  String? _selectedCategory;
  bool _bulkRunning = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentIds = widget.projects.map((p) => p.id).toSet();
    _selectedIds.removeWhere((id) => !currentIds.contains(id));
  }

  bool get _isSelectionMode => _selectedIds.isNotEmpty;

  List<RavenProject> get _selectedProjects =>
      widget.projects.where((p) => _selectedIds.contains(p.id)).toList();

  List<RavenProject> get _selectedActive =>
      _selectedProjects.where((p) => !p.isTrashed).toList();

  List<RavenProject> get _selectedTrashed =>
      _selectedProjects.where((p) => p.isTrashed).toList();

  bool get _allActiveFavorite =>
      _selectedActive.isNotEmpty &&
      _selectedActive.every((p) => p.isFavorite);

  bool get _canMakePublic => _selectedActive.any(
      (p) => !p.isAudioProtected && !p.requiresAppPin && !p.isPublic);

  bool get _canMakePrivate => _selectedActive.any((p) => p.isPublic);

  void _enterSelection(String projectId) {
    HapticFeedback.mediumImpact();
    setState(() => _selectedIds.add(projectId));
  }

  void _toggleSelection(String projectId) {
    setState(() {
      if (_selectedIds.contains(projectId)) {
        _selectedIds.remove(projectId);
      } else {
        _selectedIds.add(projectId);
      }
    });
  }

  void _clearSelection() {
    if (_selectedIds.isEmpty) return;
    setState(_selectedIds.clear);
  }

  void _selectAll(List<RavenProject> visible) {
    setState(() {
      final visibleIds = visible.map((p) => p.id).toSet();
      final allAlreadySelected = _selectedIds.length == visibleIds.length &&
          _selectedIds.containsAll(visibleIds);
      if (allAlreadySelected) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(visibleIds);
      }
    });
  }

  void _setFilter(LibraryFilter filter) {
    _clearSelection();
    setState(() {
      _filter = filter;
      _selectedCategory = null;
    });
  }

  void _setCategory(String? category) {
    _clearSelection();
    setState(() {
      _selectedCategory = category;
      if (category != null) _filter = LibraryFilter.all;
    });
  }

  Future<void> _runBulk({
    required List<RavenProject> projects,
    required Future<void> Function(RavenProject) action,
    required String Function(int successCount) successMessage,
  }) async {
    if (projects.isEmpty || _bulkRunning) return;
    setState(() => _bulkRunning = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failures = <String>[];
    for (final p in projects) {
      try {
        await action(p);
      } catch (e) {
        failures.add('${p.title}: $e');
      }
    }
    if (!mounted) return;
    setState(() => _bulkRunning = false);
    _clearSelection();
    final success = projects.length - failures.length;
    final base = successMessage(success);
    final message = failures.isEmpty
        ? base
        : '$base · ${failures.length} ${tr(widget.preferences, 'failed', 'échoué(s)')}';
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _bulkFavorite() async {
    final active = _selectedActive;
    if (active.isEmpty) return;
    final allFav = _allActiveFavorite;
    final targets =
        allFav ? active : active.where((p) => !p.isFavorite).toList();
    await _runBulk(
      projects: targets,
      action: widget.onFavorite,
      successMessage: (n) => allFav
          ? tr(widget.preferences, 'Removed $n from favourites',
              '$n retiré(s) des favoris')
          : tr(widget.preferences, 'Added $n to favourites',
              '$n ajouté(s) aux favoris'),
    );
  }

  Future<void> _bulkCategory() async {
    final active = _selectedActive;
    if (active.isEmpty) return;
    final category = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(tr(widget.preferences, 'Move to category',
            'Déplacer vers une catégorie')),
        children: widget.categories
            .map(
              (name) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, name),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.folder_outlined),
                    const SizedBox(width: 12),
                    Text(name),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
    if (category == null || !mounted) return;
    final targets = active.where((p) => p.category != category).toList();
    await _runBulk(
      projects: targets,
      action: (p) => widget.onAssignCategory(p.copyWith(category: category)),
      successMessage: (n) => tr(widget.preferences,
          'Moved $n to "$category"', '$n déplacé(s) vers « $category »'),
    );
  }

  Future<void> _bulkTrash() async {
    final active = _selectedActive;
    if (active.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(
          widget.preferences,
          active.length == 1
              ? 'Move 1 recording to trash?'
              : 'Move ${active.length} recordings to trash?',
          active.length == 1
              ? 'Déplacer 1 enregistrement dans la corbeille ?'
              : 'Déplacer ${active.length} enregistrements dans la corbeille ?',
        )),
        content: Text(tr(widget.preferences,
            'You can restore them later from Trash.',
            'Vous pourrez les restaurer depuis la corbeille.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(widget.preferences, 'Move to trash',
                'Mettre à la corbeille')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runBulk(
      projects: active,
      action: widget.onTrash,
      successMessage: (n) => tr(widget.preferences,
          'Moved $n to trash', '$n déplacé(s) dans la corbeille'),
    );
  }

  Future<void> _bulkRestore() async {
    final trashed = _selectedTrashed;
    if (trashed.isEmpty) return;
    await _runBulk(
      projects: trashed,
      action: widget.onRestore,
      successMessage: (n) =>
          tr(widget.preferences, 'Restored $n', '$n restauré(s)'),
    );
  }

  Future<void> _bulkDelete() async {
    final all = _selectedProjects;
    if (all.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(
          widget.preferences,
          all.length == 1
              ? 'Delete 1 recording permanently?'
              : 'Delete ${all.length} recordings permanently?',
          all.length == 1
              ? 'Supprimer 1 enregistrement définitivement ?'
              : 'Supprimer ${all.length} enregistrements définitivement ?',
        )),
        content: Text(tr(
            widget.preferences,
            'This removes them and their audio from this device. This action cannot be undone.',
            'Cela supprime ces projets et leur audio de cet appareil. Action irréversible.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr(widget.preferences, 'Cancel', 'Annuler')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr(widget.preferences, 'Delete permanently',
                'Supprimer définitivement')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runBulk(
      projects: all,
      action: widget.onDelete,
      successMessage: (n) =>
          tr(widget.preferences, 'Deleted $n', '$n supprimé(s)'),
    );
  }

  Future<void> _bulkVisibility({required bool makePublic}) async {
    final active = _selectedActive;
    if (active.isEmpty) return;
    final targets = makePublic
        ? active
            .where((p) => !p.isPublic && !p.isAudioProtected && !p.requiresAppPin)
            .toList()
        : active.where((p) => p.isPublic).toList();
    if (targets.isEmpty) return;
    final skipped = active.length - targets.length;
    await _runBulk(
      projects: targets,
      action: widget.onToggleVisibility,
      successMessage: (n) {
        final base = makePublic
            ? tr(widget.preferences, 'Made $n public',
                '$n rendu(s) public(s)')
            : tr(widget.preferences, 'Made $n private',
                '$n rendu(s) privé(s)');
        return skipped > 0
            ? '$base · $skipped ${tr(widget.preferences, 'skipped', 'ignoré(s)')}'
            : base;
      },
    );
  }

  Future<void> _bulkShare() async {
    final active = _selectedActive;
    if (active.isEmpty) return;
    final handler = widget.onShareProjects;
    if (handler == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await handler(active);
      if (!mounted) return;
      _clearSelection();
    } catch (e) {
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(
        content: Text(
            '${tr(widget.preferences, 'Could not share', 'Impossible de partager')}: $e'),
      ));
    }
  }

  Widget _buildNormalHeader({
    required ThemeData theme,
    required List<RavenProject> visible,
    required String query,
    required double horizontalPadding,
    required bool isCompact,
  }) {
    return Padding(
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
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.audiotrack_rounded),
                      title: Text(tr(widget.preferences, 'Import audio files',
                          'Importer des fichiers audio')),
                      subtitle: Text(tr(widget.preferences,
                          'One or more recordings (m4a, mp3, wav, flac…)',
                          'Un ou plusieurs enregistrements (m4a, mp3, wav, flac…)')),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'project',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_zip_outlined),
                      title: Text(tr(widget.preferences,
                          'Import RAVEN projects',
                          'Importer des projets RAVEN')),
                      subtitle: Text(tr(widget.preferences,
                          'One or more .zip bundles',
                          'Un ou plusieurs fichiers .zip')),
                    ),
                  ),
                ],
                icon: const Icon(Icons.file_upload_outlined),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            query.isEmpty
                ? '${visible.length} ${tr(widget.preferences, visible.length == 1 ? 'recording' : 'recordings', visible.length == 1 ? 'enregistrement' : 'enregistrements')}'
                : '${visible.length} ${tr(widget.preferences, 'of', 'sur')} ${widget.projects.where((p) => _filter != LibraryFilter.trash ? !p.isTrashed : p.isTrashed).length}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 17),
          TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: tr(widget.preferences, 'Search title, category or tag',
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
  }

  Widget _buildSelectionHeader({
    required ThemeData theme,
    required List<RavenProject> visible,
    required double horizontalPadding,
    required bool isCompact,
  }) {
    final count = _selectedIds.length;
    final allVisibleSelected = visible.isNotEmpty &&
        _selectedIds.length == visible.length &&
        _selectedIds.containsAll(visible.map((p) => p.id));

    return Material(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            horizontalPadding, isCompact ? 8 : 14, horizontalPadding, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  tooltip: tr(widget.preferences, 'Exit selection',
                      'Quitter la sélection'),
                  onPressed: _clearSelection,
                  icon: const Icon(Icons.close_rounded),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '$count ${tr(widget.preferences, 'selected', 'sélectionné(s)')}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                if (visible.isNotEmpty)
                  TextButton.icon(
                    onPressed:
                        _bulkRunning ? null : () => _selectAll(visible),
                    icon: Icon(
                      allVisibleSelected
                          ? Icons.deselect_rounded
                          : Icons.select_all_rounded,
                      size: 18,
                    ),
                    label: Text(allVisibleSelected
                        ? tr(widget.preferences, 'Clear', 'Effacer')
                        : tr(widget.preferences, 'All', 'Tout')),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  if (_selectedActive.isNotEmpty)
                    _selectionChip(
                      icon: _allActiveFavorite
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      label: _allActiveFavorite
                          ? tr(widget.preferences, 'Unfavourite', 'Retirer')
                          : tr(widget.preferences, 'Favourite', 'Favori'),
                      onPressed: _bulkFavorite,
                    ),
                  if (_selectedActive.isNotEmpty)
                    _selectionChip(
                      icon: Icons.folder_outlined,
                      label:
                          tr(widget.preferences, 'Category', 'Catégorie'),
                      onPressed: _bulkCategory,
                    ),
                  if (_selectedActive.isNotEmpty)
                    _selectionChip(
                      icon: Icons.delete_outline_rounded,
                      label: tr(widget.preferences, 'Trash', 'Corbeille'),
                      onPressed: _bulkTrash,
                    ),
                  if (_selectedTrashed.isNotEmpty)
                    _selectionChip(
                      icon: Icons.restore_rounded,
                      label: tr(widget.preferences, 'Restore', 'Restaurer'),
                      onPressed: _bulkRestore,
                    ),
                  if (_canMakePublic)
                    _selectionChip(
                      icon: Icons.public_rounded,
                      label: tr(widget.preferences, 'Make public',
                          'Rendre public'),
                      onPressed: () => _bulkVisibility(makePublic: true),
                    ),
                  if (_canMakePrivate)
                    _selectionChip(
                      icon: Icons.lock_outline_rounded,
                      label: tr(widget.preferences, 'Make private',
                          'Rendre privé'),
                      onPressed: () => _bulkVisibility(makePublic: false),
                    ),
                  if (widget.onShareProjects != null &&
                      _selectedActive.isNotEmpty)
                    _selectionChip(
                      icon: Icons.share_outlined,
                      label: tr(widget.preferences, 'Share', 'Partager'),
                      onPressed: _bulkShare,
                    ),
                  if (_selectedProjects.isNotEmpty)
                    _selectionChip(
                      icon: Icons.delete_forever_rounded,
                      label: tr(widget.preferences, 'Delete', 'Supprimer'),
                      onPressed: _bulkDelete,
                      tint: theme.colorScheme.error,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionChip({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? tint,
  }) {
    final theme = Theme.of(context);
    final c = tint ?? theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: theme.colorScheme.surface,
        shape: StadiumBorder(
          side: BorderSide(color: c.withValues(alpha: 0.35)),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: _bulkRunning ? null : onPressed,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 16, color: c),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: c,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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

          final header = _isSelectionMode
              ? _buildSelectionHeader(
                  theme: theme,
                  visible: visible,
                  horizontalPadding: horizontalPadding,
                  isCompact: isCompact,
                )
              : _buildNormalHeader(
                  theme: theme,
                  visible: visible,
                  query: query,
                  horizontalPadding: horizontalPadding,
                  isCompact: isCompact,
                );

          final filterChips = _isSelectionMode
              ? null
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      _FilterChip(
                        label: tr(widget.preferences, 'All', 'Tous'),
                        selected: _filter == LibraryFilter.all,
                        onTap: () => _setFilter(LibraryFilter.all),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: tr(
                            widget.preferences, 'Favourites', 'Favoris'),
                        selected: _filter == LibraryFilter.favorites,
                        onTap: () => _setFilter(LibraryFilter.favorites),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: tr(widget.preferences, 'Trash', 'Corbeille'),
                        selected: _filter == LibraryFilter.trash,
                        onTap: () => _setFilter(LibraryFilter.trash),
                      ),
                    ],
                  ),
                );

          final results = Expanded(
            child: visible.isEmpty
                ? _EmptyLibrary(
                    preferences: widget.preferences,
                    filter: _filter,
                    hasSearch: query.isNotEmpty,
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 8, horizontalPadding, 24),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final project = visible[index];
                      final isSelected = _selectedIds.contains(project.id);
                      return ProjectTile(
                        project: project,
                        preferences: widget.preferences,
                        selectionMode: _isSelectionMode,
                        isSelected: isSelected,
                        onLongPress: _isSelectionMode
                            ? null
                            : () => _enterSelection(project.id),
                        onToggleSelection: _isSelectionMode
                            ? () => _toggleSelection(project.id)
                            : null,
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
                        onTogglePin:
                            project.isTrashed || widget.onTogglePin == null
                                ? null
                                : () => widget.onTogglePin!(project),
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
                        onFilter: _setFilter,
                        onCategory: _setCategory,
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
                              onFilter: _setFilter,
                              onCategory: _setCategory,
                              onManageCategories: () =>
                                  _manageCategories(context),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: Column(
                              children: <Widget>[
                                header,
                                if (filterChips != null)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        28, 4, 28, 4),
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
                if (project.sessions.isNotEmpty &&
                    project.sessions.last.sampleRate > 0)
                  _detailRow(
                    widget.preferences,
                    'Sample rate',
                    '${(project.sessions.last.sampleRate / 1000).toStringAsFixed(1)} kHz',
                  ),
                _detailRow(widget.preferences, 'Category', project.category),
                _detailRow(
                    widget.preferences,
                    'Privacy',
                    project.isAudioProtected
                        ? tr(
                            widget.preferences,
                            'Encrypted — always private',
                            'Chiffré — toujours privé')
                        : project.isPublic
                            ? tr(
                                widget.preferences,
                                'Public — visible in your device Files app',
                                'Public — visible dans les fichiers de l’appareil')
                            : tr(
                                widget.preferences,
                                'Private — stored inside RAVEN only',
                                'Privé — stocké uniquement dans RAVEN')),
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
        content: Text(
          '${tr(widget.preferences, 'Could not update recording visibility', 'Impossible de modifier la visibilité')}: $error',
        ),
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
    final minutes =
        duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        duration.inSeconds.remainder(60).toString().padLeft(2, '0');
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
          title: Text(tr(widget.preferences, 'Rename category',
              'Renommer la catégorie')),
          content: TextField(
            controller: nameController,
            autofocus: true,
            maxLength: 60,
            onSubmitted: (value) =>
                Navigator.pop(dialogContext, value.trim()),
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
    this.selectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelection,
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
    this.onTogglePin,
    super.key,
  });

  final RavenProject project;
  final AppPreferences preferences;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelection;
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
  final VoidCallback? onTogglePin;

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final showResumeButton = !selectionMode &&
            onResume != null &&
            !project.isDraft &&
            !project.isTrashed &&
            !project.isAudioProtected &&
            constraints.maxWidth >= 340;

        final bg = selectionMode && isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
            : theme.colorScheme.surfaceContainerLow;
        final borderColor = selectionMode && isSelected
            ? theme.colorScheme.primary
            : Colors.transparent;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: borderColor,
              width: selectionMode && isSelected ? 1.5 : 0,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: selectionMode ? onToggleSelection : onTap,
              onLongPress: selectionMode ? null : onLongPress,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 7, 14),
                child: Row(
                  children: <Widget>[
                    selectionMode
                        ? _selectionLeading(theme)
                        : _leadingIcon(theme),
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
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary)),
                          ],
                        ],
                      ),
                    ),
                    if (!selectionMode) ...<Widget>[
                      if (showResumeButton)
                        IconButton(
                          tooltip: project.isStandalone
                              ? tr(preferences, 'Resume recording',
                                  'Reprendre l’enregistrement')
                              : tr(preferences, 'Add a recording',
                                  'Ajouter un enregistrement'),
                          onPressed: onResume,
                          icon: const Icon(Icons.mic_rounded),
                          visualDensity: VisualDensity.compact,
                        ),
                      if (!project.isTrashed && onFavorite != null)
                        IconButton(
                          tooltip: project.isFavorite
                              ? tr(preferences, 'Remove favourite',
                                  'Retirer des favoris')
                              : tr(preferences, 'Add favourite',
                                  'Ajouter aux favoris'),
                          onPressed: onFavorite,
                          icon: Icon(
                              project.isFavorite
                                  ? Icons.star_rounded
                                  : Icons.star_border_rounded,
                              color: project.isFavorite
                                  ? theme.colorScheme.tertiary
                                  : null),
                        ),
                      _popupMenu(context),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _leadingIcon(ThemeData theme) {
    final iconData = project.isTrashed
        ? Icons.delete_outline_rounded
        : project.isStandalone
            ? Icons.mic_none_rounded
            : Icons.audio_file_outlined;

    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(15)),
            child: Icon(iconData, color: theme.colorScheme.primary),
          ),
          if (!project.isTrashed) _stateBadge(theme),
        ],
      ),
    );
  }

  Widget _selectionLeading(ThemeData theme) {
    final iconData = project.isTrashed
        ? Icons.delete_outline_rounded
        : project.isStandalone
            ? Icons.mic_none_rounded
            : Icons.audio_file_outlined;

    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              iconData,
              color: isSelected
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.primary,
            ),
          ),
          if (isSelected)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: theme.colorScheme.surface, width: 2),
                ),
                child: Icon(Icons.check_rounded,
                    size: 10, color: theme.colorScheme.onPrimary),
              ),
            ),
          if (!project.isTrashed && !isSelected) _stateBadge(theme),
        ],
      ),
    );
  }

  Widget _stateBadge(ThemeData theme) {
    if (project.isAudioProtected) {
      return _badge(
        theme,
        icon: Icons.lock_rounded,
        background: theme.colorScheme.tertiary,
        foreground: theme.colorScheme.onTertiary,
        tooltip: tr(preferences, 'Encrypted — password required',
            'Chiffré — mot de passe requis'),
      );
    }
    if (project.requiresAppPin) {
      return _badge(
        theme,
        icon: Icons.pin_rounded,
        background: theme.colorScheme.secondary,
        foreground: theme.colorScheme.onSecondary,
        tooltip:
            tr(preferences, 'Requires RAVEN PIN', 'Nécessite le PIN RAVEN'),
      );
    }
    if (project.isPublic) {
      return _badge(
        theme,
        icon: Icons.public_rounded,
        background: theme.colorScheme.primary,
        foreground: theme.colorScheme.onPrimary,
        tooltip: tr(preferences, 'Public — visible in your Files app',
            'Public — visible dans vos fichiers'),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _badge(
    ThemeData theme, {
    required IconData icon,
    required Color background,
    required Color foreground,
    required String tooltip,
  }) {
    return Positioned(
      right: 0,
      bottom: 0,
      child: Tooltip(
        message: tooltip,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: background,
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.surface, width: 1.5),
          ),
          child: Icon(icon, size: 10, color: foreground),
        ),
      ),
    );
  }

  Widget _popupMenu(BuildContext context) {
    final hasAnyAction = onResume != null ||
        onDetails != null ||
        onAssignCategory != null ||
        onCreateProject != null ||
        onShare != null ||
        onToggleVisibility != null ||
        onToggleProtection != null ||
        onRename != null ||
        onTrash != null ||
        onRestore != null ||
        onDelete != null;

    if (!hasAnyAction) return const SizedBox(width: 8);

    return PopupMenuButton<String>(
      tooltip: tr(preferences, 'Project actions', 'Actions du projet'),
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
          case 'pin':
            onTogglePin?.call();
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
            child: Text(tr(preferences, 'Create project', 'Créer un projet')),
          ),
        if (onShare != null)
          PopupMenuItem(
            value: 'share',
            child: Text(tr(preferences, 'Share audio', 'Partager l’audio')),
          ),
        if (onToggleVisibility != null)
          PopupMenuItem(
            value: 'visibility',
            child: Text(tr(
              preferences,
              project.isPublic
                  ? (project.isStandalone
                      ? 'Make recording private'
                      : 'Make project private')
                  : (project.isStandalone
                      ? 'Make recording public'
                      : 'Make project public'),
              project.isPublic
                  ? (project.isStandalone
                      ? 'Rendre l’enregistrement privé'
                      : 'Rendre le projet privé')
                  : (project.isStandalone
                      ? 'Rendre l’enregistrement public'
                      : 'Rendre le projet public'),
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
        if (onTogglePin != null)
          PopupMenuItem(
            value: 'pin',
            child: Text(tr(
              preferences,
              project.requiresAppPin ? 'Remove PIN lock' : 'Lock with PIN',
              project.requiresAppPin
                  ? 'Retirer le verrouillage PIN'
                  : 'Verrouiller par PIN',
            )),
          ),
        if (onResume != null)
          PopupMenuItem(
            value: 'resume',
            child: Text(
              project.isStandalone
                  ? tr(preferences, 'Resume recording',
                      'Reprendre l’enregistrement')
                  : tr(preferences, 'Add a recording',
                      'Ajouter un enregistrement'),
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
  final ValueChanged<String?> onCategory;
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
  const _EmptyLibrary({
    required this.preferences,
    required this.filter,
    this.hasSearch = false,
  });
  final AppPreferences preferences;
  final LibraryFilter filter;
  final bool hasSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (hasSearch) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.search_off_rounded,
                  size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 14),
              Text(
                tr(preferences, 'No matches', 'Aucun résultat'),
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 7),
              Text(
                tr(
                    preferences,
                    'Try a different title, category or tag.',
                    'Essayez un autre titre, catégorie ou étiquette.'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

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
            if (filter == LibraryFilter.all) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                tr(
                    preferences,
                    'Tip: long-press any recording to select several and act on them at once.',
                    'Astuce : maintenez un enregistrement appuyé pour en sélectionner plusieurs et les gérer ensemble.'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}