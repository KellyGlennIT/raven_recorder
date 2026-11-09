import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:raven/models/raven_project.dart';
import 'package:raven/screens/library_screen.dart';
import 'package:raven/screens/standalone_recording_screen.dart';
import 'package:raven/services/app_preferences.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('fr');
    Intl.defaultLocale = 'en';
  });

  testWidgets('Library screen offers PIN lock toggle directly from recording menu',
      (tester) async {
    final now = DateTime(2026, 11, 8);
    final recording = RavenProject(
      id: 'rec_1',
      title: 'Voice Note',
      createdAt: now,
      updatedAt: now,
      sessions: const <RavenAudioSession>[],
      isStandalone: true,
      requiresAppPin: false,
    );

    var pinToggled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: LibraryScreen(
            projects: <RavenProject>[recording],
            categories: const <String>[],
            preferences: AppPreferences(),
            onOpenProject: (_) async {},
            onFavorite: (_) async {},
            onRename: (_) async {},
            onTrash: (_) async {},
            onRestore: (_) async {},
            onDelete: (_) async {},
            onImportProject: () {},
            onImportAudio: () {},
            onResumeProject: (_) async {},
            onCreateCategory: (_) async {},
            onRenameCategory: (_, __) async {},
            onDeleteCategory: (_) async {},
            onAssignCategory: (_) async {},
            onCreateProject: (_) async {},
            onShareProject: (_) async {},
            onToggleVisibility: (_) async {},
            onToggleProtection: (_) async {},
            onTogglePin: (p) async {
              pinToggled = true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Project actions'));
    await tester.pumpAndSettle();

    expect(find.text('Lock with PIN'), findsOneWidget);
    await tester.tap(find.text('Lock with PIN'));
    await tester.pumpAndSettle();

    expect(pinToggled, isTrue);
  });

  testWidgets('Standalone recording screen offers PIN lock in menu without project tab',
      (tester) async {
    final now = DateTime(2026, 11, 8);
    final recording = RavenProject(
      id: 'rec_2',
      title: 'Private Note',
      createdAt: now,
      updatedAt: now,
      sessions: const <RavenAudioSession>[],
      isStandalone: true,
      requiresAppPin: false,
    );

    var pinToggled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: StandaloneRecordingScreen(
          project: recording,
          preferences: AppPreferences(),
          onResume: () {},
          onOpenDetails: () {},
          onCreateProject: () {},
          onShare: () async {},
          onRename: (_) async => true,
          onToggleEncryption: () async {},
          onToggleVisibility: () async => null,
          onTogglePin: () async {
            pinToggled = true;
          },
          autoPlay: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();

    expect(find.text('Require PIN to open'), findsOneWidget);
    await tester.tap(find.text('Require PIN to open'));
    await tester.pumpAndSettle();

    expect(pinToggled, isTrue);
  });
}