import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raven/models/raven_project.dart';
import 'package:raven/screens/home_screen.dart';
import 'package:raven/screens/library_screen.dart';
import 'package:raven/screens/settings_screen.dart';
import 'package:raven/services/app_preferences.dart';

void main() {
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
              onViewLibrary: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Viewport: $size');
    }
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
              onResumeProject: (_) {},
              onCreateCategory: (_) async {},
              onRenameCategory: (_, __) async {},
              onDeleteCategory: (_) async {},
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
              onOpenScheduledRecordings: () {},
              onApplyPublicVisibility: ({required visible}) async {},
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
