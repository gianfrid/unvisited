import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:unvisited/recording/position_source.dart' show PositionFix;
import 'package:unvisited/ui/cassette_key.dart';
import 'package:unvisited/ui/settings_sheet.dart' show SettingsSheet;

import 'helpers.dart';

/// A pushed fix, the recording tests' `fakeFix` (app_model_test.dart)
/// distilled: one [FakePositionSource] event, enough to move a session
/// past its first fix.
void fakeFix(FakePositionSource source, double lat, [double? ele]) {
  source.controller.add(
    PositionFix(
      time: DateTime.now(),
      lat: lat,
      lon: 13.4050,
      ele: ele,
      accuracy: 5.0,
    ),
  );
}

void main() {
  testWidgets(
    'cassette record cluster latches REC and blinks while recording',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setButtonStyle('cassette');
      mockGeolocator(
        tester,
        permission: 3,
        position: {'lat': 52.5200, 'lon': 13.4050},
      );

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();
      await tester.pump();

      // The deck key that carries the given glyph.
      CassetteKey deckKey(IconData icon) => tester.widget<CassetteKey>(
        find
            .ancestor(of: find.byIcon(icon), matching: find.byType(CassetteKey))
            .first,
      );

      // Idle: the REC key rides raised with a dark LED, and the pause and
      // stop keys do not exist yet.
      expect(deckKey(Icons.fiber_manual_record).latched, isFalse);
      expect(deckKey(Icons.fiber_manual_record).led, CassetteLed.off);
      expect(find.byIcon(Icons.stop), findsNothing);

      final source = FakePositionSource();
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 52.5200, 42.0);
      fakeFix(source, 52.5201, 43.0);
      await tester.pump();
      await tester.pump();

      // Recording: REC is latched with the LED blinking, and pausing moved
      // to its own raised key, with Stop alongside.
      expect(deckKey(Icons.fiber_manual_record).latched, isTrue);
      expect(deckKey(Icons.fiber_manual_record).led, CassetteLed.blink);
      expect(deckKey(Icons.pause).latched, isFalse);
      expect(find.byIcon(Icons.stop), findsOneWidget);

      // The blink loops: pumps step it without an exception (it never
      // settles, so pumpAndSettle is off the table while it runs).
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);

      // Paused: the pause key latches (reading Resume), REC stays down and
      // its LED goes steady — the deck-standby convention.
      model.pauseRecording();
      await tester.pump();
      expect(deckKey(Icons.play_arrow).latched, isTrue);
      expect(deckKey(Icons.fiber_manual_record).latched, isTrue);
      expect(deckKey(Icons.fiber_manual_record).led, CassetteLed.steady);

      // Resumed: the pause key rides raised again and the LED blinks.
      model.resumeRecording();
      await tester.pump();
      expect(deckKey(Icons.pause).latched, isFalse);
      expect(deckKey(Icons.fiber_manual_record).led, CassetteLed.blink);
    },
  );

  testWidgets('the standard style keeps the flat actions', (tester) async {
    final model = await createModel();
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );

    await pumpMapPage(
      tester,
      model: model,
      cache: createCache(),
      locationSupported: true,
    );
    await tester.pump();

    expect(model.buttonStyle, 'standard');
    expect(find.byType(CassetteKey), findsNothing);
    expect(find.byType(CassetteDeck), findsNothing);
    // The flat record action, exactly as before the style existed.
    expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget);
  });

  testWidgets('Settings switches the button style to cassette', (tester) async {
    final model = await createModel();

    await pumpMapPage(
      tester,
      model: model,
      cache: createCache(),
      locationSupported: false,
    );
    await tester.pump();
    expect(find.byType(CassetteKey), findsNothing);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Button style'), findsOneWidget);

    // Scoped to the sheet: the map behind it may carry the same words.
    final sheet = find.byType(SettingsSheet);
    await tester.ensureVisible(
      find.descendant(of: sheet, matching: find.text('Cassette')),
    );
    await tester.tap(
      find.descendant(of: sheet, matching: find.text('Cassette')),
    );
    await tester.pumpAndSettle();
    expect(model.buttonStyle, 'cassette');

    // The deck chrome is already live behind the sheet: the control pill
    // and toolbar keys drew as transport keys.
    expect(find.byType(CassetteKey), findsWidgets);
    expect(find.byType(CassetteDeck), findsOneWidget);

    // And back: the flat style returns with the setting. 'Standard' also
    // labels the map-layer segment, so the tap is aimed at this sheet's
    // own button-style segment specifically.
    final segments = find.byWidgetPredicate(
      (w) => w is SegmentedButton<String>,
    );
    final styleSegment = tester
        .widgetList<SegmentedButton<String>>(segments)
        .firstWhere((b) => b.segments.any((s) => s.value == 'cassette'));
    final standardInStyle = find.descendant(
      of: find.byWidgetPredicate((w) => identical(w, styleSegment)),
      matching: find.text('Standard'),
    );
    await tester.ensureVisible(standardInStyle);
    await tester.tap(standardInStyle);
    await tester.pumpAndSettle();
    expect(model.buttonStyle, 'standard');
    expect(find.byType(CassetteKey), findsNothing);
  });
}
