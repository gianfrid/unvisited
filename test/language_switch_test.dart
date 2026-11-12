import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/main.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';

/// End-to-end language switching through the real app root: the Settings
/// sheet picker must rebuild the whole UI in the chosen language, not just
/// the sheet.
void main() {
  Directory createRoot() {
    final root = Directory.systemTemp.createTempSync('unvisited-store');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    return root;
  }

  Directory createCache() {
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // See above.
      }
    });
    return cache;
  }

  Future<AppModel> pumpApp(WidgetTester tester,
      {String? language, Locale? deviceLocale}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final model = AppModel(TrackStore(createRoot()));
    await model.load();
    if (language != null) await model.setLanguage(language);
    await tester.pumpWidget(UnvisitedApp(
      model: model,
      cacheDir: createCache(),
      versionFuture: Future.value('2026-11-12 12:00'),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return model;
  }

  Future<void> openSettings(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('the settings sheet switches the UI to Italian', (tester) async {
    final model = await pumpApp(tester, language: 'en');
    expect(find.text('Import'), findsOneWidget);

    await openSettings(tester, 'Settings');
    // The row shows the current choice and lives at the bottom of a
    // scrollable sheet.
    await tester.ensureVisible(find.text('Language'));
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);

    await tester.tap(find.text('Language'));
    await tester.pumpAndSettle();
    // The picker offers the system language plus every supported one,
    // each named in itself.
    expect(find.text('System language'), findsOneWidget);
    expect(find.text('Italiano'), findsOneWidget);

    await tester.tap(find.text('Italiano'));
    await tester.pumpAndSettle();

    // Persisted...
    expect(model.language, 'it');
    // ...and the whole UI behind the sheet is Italian now.
    expect(find.text('Importa'), findsOneWidget);
    expect(find.text('Import'), findsNothing);
    expect(find.text('Ancora nessuna traccia'), findsOneWidget);

    // Close the sheet, then reopen it: it comes back in Italian.
    Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
    await tester.pumpAndSettle();
    await openSettings(tester, 'Impostazioni');
    expect(find.text('Lingua'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching back to the system language follows the device',
      (tester) async {
    final model = await pumpApp(tester, language: 'it');
    expect(find.text('Importa'), findsOneWidget);

    await openSettings(tester, 'Impostazioni');
    await tester.ensureVisible(find.text('Lingua'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lingua'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lingua di sistema'));
    await tester.pumpAndSettle();

    expect(model.language, 'system');
    expect(model.locale, isNull);
    // The test device reports English, so the UI is English again.
    expect(find.text('Import'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stored Italian choice is applied at startup',
      (tester) async {
    await pumpApp(tester, language: 'it');

    expect(find.text('Importa'), findsOneWidget);
    expect(find.text('Tracce'), findsOneWidget);
    expect(find.text('Impostazioni'), findsOneWidget);
  });
}
