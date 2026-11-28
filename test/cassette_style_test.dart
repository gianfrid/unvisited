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
  testWidgets('cassette record key latches and blinks through a session', (
    tester,
  ) async {
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

    // Idle: the single record key rides raised with a dark LED and the
    // red REC glyph; no stop key exists yet.
    expect(deckKey(Icons.fiber_manual_record).latched, isFalse);
    expect(deckKey(Icons.fiber_manual_record).led, CassetteLed.off);
    expect(deckKey(Icons.fiber_manual_record).rec, isTrue);
    expect(find.byIcon(Icons.stop), findsNothing);

    final source = FakePositionSource();
    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 52.5200, 42.0);
    fakeFix(source, 52.5201, 43.0);
    await tester.pump();
    await tester.pump();

    // Recording: the same key, latched down, reading Pause with the LED
    // blinking; Stop rides above it.
    expect(deckKey(Icons.pause).latched, isTrue);
    expect(deckKey(Icons.pause).led, CassetteLed.blink);
    expect(deckKey(Icons.pause).rec, isFalse);
    expect(find.byIcon(Icons.stop), findsOneWidget);

    // The blink loops: pumps step it without an exception (it never
    // settles, so pumpAndSettle is off the table while it runs).
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    // Paused: still latched, reading Resume, LED steady — the deck's
    // standby convention.
    model.pauseRecording();
    await tester.pump();
    expect(deckKey(Icons.play_arrow).latched, isTrue);
    expect(deckKey(Icons.play_arrow).led, CassetteLed.steady);

    // Resumed: back to the latched Pause with the LED blinking.
    model.resumeRecording();
    await tester.pump();
    expect(deckKey(Icons.pause).latched, isTrue);
    expect(deckKey(Icons.pause).led, CassetteLed.blink);
  });

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
    // and toolbar keys drew as floating transport keys — no panel
    // behind them, so nothing but the keys themselves changed type.
    expect(find.byType(CassetteKey), findsWidgets);

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

  testWidgets('the cassette scrubber dresses the slider as a transport bar', (
    tester,
  ) async {
    double? dragged;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CassetteScrubber(value: 0.5, onChanged: (v) => dragged = v),
          ),
        ),
      ),
    );

    // The groove and the capstan thumb, not the default Material slider
    // skin (the shapes are private, so they assert by runtime type).
    final theme = tester.widget<SliderTheme>(find.byType(SliderTheme));
    expect(theme.data.trackHeight, 10);
    expect(theme.data.thumbShape.runtimeType.toString(), '_CapstanThumbShape');

    // A drag still seeks: the wrapped Slider's own behavior.
    await tester.drag(find.byType(Slider), const Offset(40, 0));
    expect(dragged, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
