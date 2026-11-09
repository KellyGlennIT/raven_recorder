import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:raven/models/raven_project.dart';
import 'package:raven/screens/home_screen.dart';
import 'package:raven/screens/library_screen.dart';
import 'package:raven/screens/settings_screen.dart';
import 'package:raven/screens/standalone_recording_screen.dart';
import 'package:raven/services/app_preferences.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('fr');
    Intl.defaultLocale = 'en';
  });
  const viewportSizes = <Size>[
    Size(320, 640),
    Size(360, 800),
    Size(600, 800),
    Size(800, 800),
  ];

  testWidgets('home screen fits compact and expanded mobile widths',
      (tester) async {
    for (final size in viewportSizes) {
      await _setViewport(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: HomeScreen(
              projects: const <RavenProject>[],
              preferences: AppPreferences(),
              onRecord: () {},
              onOpenProject: (_) {},
              onViewLibrary: () {}, categories: [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Viewport: $size');
    }
  });

  testWidgets('home record button starts capture without showing a mode choice',
      (tester) async {
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: HomeScreen(
            projects: const <RavenProject>[],
            preferences: AppPreferences(),
            onRecord: () => started = true,
            onOpenProject: (_) {},
            onViewLibrary: () {}, categories: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tap to start recording'), findsOneWidget);
    await tester.tap(find.text('Tap to start recording'));
    expect(started, isTrue);
    expect(find.text('Create project'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone recording menu offers project creation',
      (tester) async {
    final now = DateTime(2026, 11, 8);
    final recording = RavenProject(
      id: 'standalone-test',
      title: 'Voice note',
      createdAt: now,
      updatedAt: now,
      sessions: const <RavenAudioSession>[],
      isStandalone: true,
    );
    var createProjectTapped = false;
    var encrypted = false;
    var renamedTitle = '';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: StandaloneRecordingScreen(
          project: recording,
          preferences: AppPreferences(),
          onResume: () {},
          onOpenDetails: () {},
          onCreateProject: () => createProjectTapped = true,
          onShare: () async {},
          onRename: (title) async {
            renamedTitle = title;
            return true;
          },
          onToggleEncryption: () async {
            encrypted = true;
          },
          onToggleVisibility: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Share audio'), findsOneWidget);
    await tester.tap(find.text('Rename recording'));
    await tester.pumpAndSettle();
    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Recording title',
    );
    await tester.enterText(titleField, 'Renamed note');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(renamedTitle, 'Renamed note');
    expect(find.text('Renamed note'), findsOneWidget);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock audio with a password'));
    expect(encrypted, isTrue);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create project'));
    expect(createProjectTapped, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library screen fits compact and expanded mobile widths',
      (tester) async {
    for (final size in viewportSizes) {
      await _setViewport(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: LibraryScreen(
              projects: const <RavenProject>[],
              categories: const <String>['Uncategorized'],
              preferences: AppPreferences(),
              onOpenProject: (_) {},
              onFavorite: (_) {},
              onRename: (_) {},
              onTrash: (_) {},
              onRestore: (_) {},
              onDelete: (_) {},
              onImportProject: () {},
              onImportAudio: () {},
              onResumeProject: (_) {},
              onCreateCategory: (_) async {},
              onRenameCategory: (_, __) async {},
              onDeleteCategory: (_) async {},
              onAssignCategory: (_) {},
              onCreateProject: (_) {},
              onShareProject: (_) {},
              onToggleVisibility: (_) async {},
              onToggleProtection: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Viewport: $size');
      if (size.width >= 740) {
        expect(find.text('Categories'), findsOneWidget);
      }
    }
  });

  testWidgets('library category manager creates a custom category',
      (tester) async {
    final createdCategories = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: LibraryScreen(
            projects: const <RavenProject>[],
            categories: const <String>['Uncategorized'],
            preferences: AppPreferences(),
            onOpenProject: (_) {},
            onFavorite: (_) {},
            onRename: (_) {},
            onTrash: (_) {},
            onRestore: (_) {},
            onDelete: (_) {},
            onImportProject: () {},
            onImportAudio: () {},
            onResumeProject: (_) {},
            onCreateCategory: (name) async {
              createdCategories.add(name);
            },
            onRenameCategory: (_, __) async {},
            onDeleteCategory: (_) async {},
            onAssignCategory: (_) {},
            onCreateProject: (_) {},
            onShareProject: (_) {},
            onToggleVisibility: (_) async {},
            onToggleProtection: (_) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Manage categories'));
    await tester.pumpAndSettle();
    final categoryInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'New category',
    );
    await tester.enterText(categoryInput, 'Interviews');
    await tester.tap(find.byTooltip('Add category'));
    await tester.pumpAndSettle();

    expect(createdCategories, <String>['Interviews']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact library opens category and trash pages from its drawer',
      (tester) async {
    await _setViewport(tester, const Size(400, 800));
    final now = DateTime(2026, 11, 8);
    final projects = <RavenProject>[
      RavenProject(
        id: 'interview',
        title: 'Interview',
        createdAt: now,
        updatedAt: now,
        category: 'Interviews',
        sessions: const <RavenAudioSession>[],
      ),
      RavenProject(
        id: 'idea',
        title: 'Idea',
        createdAt: now,
        updatedAt: now,
        sessions: const <RavenAudioSession>[],
      ),
      RavenProject(
        id: 'trashed',
        title: 'Old take',
        createdAt: now,
        updatedAt: now,
        sessions: const <RavenAudioSession>[],
        isTrashed: true,
        trashedAt: now,
      ),
      RavenProject(
        id: 'standalone',
        title: 'Voice note',
        createdAt: now,
        updatedAt: now,
        sessions: const <RavenAudioSession>[],
        isStandalone: true,
      ),
    ];
    var promotedRecordingId = '';
    var sharedRecordingId = '';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: LibraryScreen(
            projects: projects,
            categories: const <String>['Uncategorized', 'Interviews'],
            preferences: AppPreferences(),
            onOpenProject: (_) {},
            onFavorite: (_) {},
            onRename: (_) {},
            onTrash: (_) {},
            onRestore: (_) {},
            onDelete: (_) {},
            onImportProject: () {},
            onImportAudio: () {},
            onResumeProject: (_) {},
            onCreateCategory: (_) async {},
            onRenameCategory: (_, __) async {},
            onDeleteCategory: (_) async {},
            onAssignCategory: (_) {},
            onCreateProject: (project) => promotedRecordingId = project.id,
            onShareProject: (project) => sharedRecordingId = project.id,
            onToggleVisibility: (_) async {},
            onToggleProtection: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Interview'), findsOneWidget);
    expect(find.text('Idea'), findsOneWidget);
    expect(find.text('Old take'), findsNothing);
    await tester.tap(find.byTooltip('Project actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create project'));
    expect(promotedRecordingId, 'standalone');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Project actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share audio'));
    expect(sharedRecordingId, 'standalone');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Project actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Recording details'), findsOneWidget);
    expect(find.text('Storage used'), findsOneWidget);
    expect(find.text('Recording sessions'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Open library menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Interviews').last);
    await tester.pumpAndSettle();
    expect(find.text('Interview'), findsOneWidget);
    expect(find.text('Idea'), findsNothing);

    await tester.tap(find.byTooltip('Open library menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trash').last);
    await tester.pumpAndSettle();
    expect(find.text('Old take'), findsOneWidget);
    expect(find.text('Interview'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings screen fits compact and expanded mobile widths',
      (tester) async {
    for (final size in viewportSizes) {
      await _setViewport(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: SettingsScreen(
              preferences: AppPreferences(),
              onSettingsChanged: () {},
              onShowTour: () {},
              onApplyPublicVisibility: ({required visible}) async {},
              onTrashRetentionChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Viewport: $size');
    }
  });
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}
