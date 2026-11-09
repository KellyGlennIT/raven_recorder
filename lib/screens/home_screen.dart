import 'package:flutter/material.dart';

import '../models/raven_project.dart';
import '../services/app_preferences.dart';
import 'library_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.projects,
    required this.categories,
    required this.preferences,
    required this.onRecord,
    required this.onOpenProject,
    required this.onViewLibrary,
    super.key,
  });

  final List<RavenProject> projects;
  final List<String> categories;
  final AppPreferences preferences;
  final VoidCallback onRecord;
  final ValueChanged<RavenProject> onOpenProject;
  final VoidCallback onViewLibrary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = projects.where((project) => !project.isTrashed).toList();
    final recent = available.take(4).toList();

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isCompact = constraints.maxWidth < 600;
          final horizontalPadding = isCompact ? 16.0 : 28.0;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  isCompact ? 16 : 28,
                  horizontalPadding,
                  28,
                ),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(
                            colors: <Color>[
                              theme.colorScheme.primary,
                              theme.colorScheme.tertiary
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: Icon(Icons.graphic_eq_rounded,
                            color: theme.colorScheme.onPrimary, size: 28),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('RAVEN',
                                style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 3.0)),
                            Text(
                              tr(preferences, 'Your personal audio workspace',
                                  'Votre espace audio personnel'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: tr(preferences, 'Search recordings',
                            'Rechercher des enregistrements'),
                        onPressed: onViewLibrary,
                        icon: const Icon(Icons.search_rounded),
                      ),
                    ],
                  ),
                  SizedBox(height: isCompact ? 24 : 34),
                  Text(
                    tr(preferences, 'Every sound has a place.',
                        'Chaque son a sa place.'),
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800, height: 1.15),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr(
                        preferences,
                        'Capture ideas, conversations and moments. RAVEN keeps them ready to revisit.',
                        'Capturez vos idées, conversations et moments. RAVEN les garde prêts à retrouver.'),
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 22),
                  _CaptureCard(preferences: preferences, onRecord: onRecord),
                  const SizedBox(height: 18),
                  Row(
                    children: <Widget>[
                      Expanded(
                          child: _StatCard(
                        icon: Icons.library_music_outlined,
                        label: tr(preferences, 'Library items', 'Éléments'),
                        value: '${available.length}',
                      )),
                      const SizedBox(width: 12),
                      Expanded(
                          child: _StatCard(
                        icon: Icons.folder_copy_outlined,
                        label: tr(preferences, 'Categories', 'Catégories'),
                        value: '${categories.length}',
                      )),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                            tr(preferences, 'Recent recordings',
                                'Enregistrements récents'),
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      TextButton(
                          onPressed: onViewLibrary,
                          child: Text(tr(preferences, 'View library',
                              'Voir la bibliothèque'))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (recent.isEmpty)
                    _EmptyRecent(preferences: preferences, onRecord: onRecord)
                  else
                    ...recent.map((project) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: ProjectTile(
                            project: project,
                            preferences: preferences,
                            onTap: () => onOpenProject(project),
                            onFavorite: null,
                            onRename: null,
                            onTrash: null,
                            onRestore: null,
                            onDelete: null,
                          ),
                        )),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CaptureCard extends StatelessWidget {
  const _CaptureCard({required this.preferences, required this.onRecord});
  final AppPreferences preferences;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: <Color>[
            theme.colorScheme.primaryContainer,
            theme.colorScheme.surfaceContainerHighest
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.mic_none_rounded,
                  size: 25, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  tr(preferences, 'Ready when you are',
                      'Prêt quand vous l’êtes'),
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(preferences.recordingFormat.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.3, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            tr(
                preferences,
                'Start a private standalone recording immediately. If it grows into something bigger, create a project from its menu.',
                'Démarrez immédiatement un enregistrement autonome privé. S’il devient un projet plus vaste, créez un projet depuis son menu.'),
            style: theme.textTheme.bodyMedium?.copyWith(
                color:
                    theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.9),
                height: 1.45),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onRecord,
              icon: const Icon(Icons.fiber_manual_record_rounded, size: 20),
              label: Text(tr(preferences, 'Tap to start recording',
                  'Touchez pour enregistrer')),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 17),
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(height: 14),
          Text(value,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _EmptyRecent extends StatelessWidget {
  const _EmptyRecent({required this.preferences, required this.onRecord});
  final AppPreferences preferences;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Column(
        children: <Widget>[
          Icon(Icons.audio_file_outlined,
              size: 38, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
              tr(preferences, 'Your recordings will appear here',
                  'Vos enregistrements apparaîtront ici'),
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 5),
          Text(
              tr(
                  preferences,
                  'Start with a voice memo, idea, rehearsal or meeting.',
                  'Commencez par une note vocale, une idée, une répétition ou une réunion.'),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          TextButton.icon(
              onPressed: onRecord,
              icon: const Icon(Icons.mic_none_rounded),
              label: Text(tr(preferences, 'Make your first recording',
                  'Créer votre premier enregistrement'))),
        ],
      ),
    );
  }
}
