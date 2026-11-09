import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raven/services/app_preferences.dart';
import 'package:raven/widgets/audio_password_dialog.dart';

void main() {
  testWidgets('audio locking asks to create and confirm a password',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showAudioPasswordDialog(
                context,
                preferences: AppPreferences(),
                createPassword: true,
              );
            },
            child: const Text('Lock'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    expect(find.text('Create an audio password'), findsOneWidget);
    expect(find.text('Confirm password'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'my secure password');
    await tester.enterText(fields.at(1), 'different password');
    await tester.tap(find.text('Lock audio'));
    await tester.pumpAndSettle();
    expect(find.text('The passwords do not match.'), findsOneWidget);

    await tester.enterText(fields.at(1), 'my secure password');
    await tester.tap(find.text('Lock audio'));
    await tester.pumpAndSettle();
    expect(result, 'my secure password');
  });
}
