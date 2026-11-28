import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:unvisited/ui/cassette_key.dart';

/// WCAG 2.x relative luminance of a color.
double luminance(Color c) {
  // The channel values are 0..1 doubles on this Flutter version.
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2.x contrast ratio between two colors (≥ 1.0, order-free).
double contrast(Color a, Color b) {
  final l1 = luminance(a) + 0.05;
  final l2 = luminance(b) + 0.05;
  return l1 > l2 ? l1 / l2 : l2 / l1;
}

void main() {
  // The app's own schemes (main.dart): Material 3 from the same seed,
  // light and dark. The cassette tones are derived from a ColorScheme,
  // so the tests pin the exact colors the two shipped themes paint.
  final schemes = {
    for (final brightness in Brightness.values)
      brightness: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4363D8),
        brightness: brightness,
      ),
  };

  group('cassette key tones meet WCAG contrast', () {
    for (final entry in schemes.entries) {
      final (brightness, scheme) = (entry.key, entry.value);
      final tones = CassetteTones.of(scheme);

      test('$brightness: glyphs and captions read against every cap stop', () {
        for (final stop in tones.stops) {
          expect(
            contrast(tones.glyph, stop),
            greaterThanOrEqualTo(4.5),
            reason:
                'glyph/caption ${tones.glyph} vs cap stop $stop is '
                '${contrast(tones.glyph, stop).toStringAsFixed(2)}:1',
          );
        }
      });

      test('$brightness: the cap border bounds the key (≥3:1)', () {
        for (final stop in tones.stops) {
          expect(
            contrast(tones.border, stop),
            greaterThanOrEqualTo(3.0),
            reason:
                'border ${tones.border} vs cap stop $stop is '
                '${contrast(tones.border, stop).toStringAsFixed(2)}:1',
          );
        }
      });

      test('$brightness: the lit REC LED reads against every cap stop', () {
        for (final stop in tones.stops) {
          expect(
            contrast(tones.led, stop),
            greaterThanOrEqualTo(3.0),
            reason:
                'LED ${tones.led} vs cap stop $stop is '
                '${contrast(tones.led, stop).toStringAsFixed(2)}:1',
          );
        }
      });

      test('$brightness: the scrubber reads on the playback card', () {
        final scrub = CassetteScrubberTones.of(scheme);
        // The capstan against the groove: both gradient stops and its
        // edge (a hardcoded light cap once measured 1.09:1 here).
        for (final thumb in [scrub.thumbFace, scrub.thumbFaceShade]) {
          expect(
            contrast(thumb, scrub.groove),
            greaterThanOrEqualTo(3.0),
            reason:
                'thumb $thumb vs groove is '
                '${contrast(thumb, scrub.groove).toStringAsFixed(2)}:1',
          );
        }
        expect(
          contrast(scrub.thumbEdge, scrub.groove),
          greaterThanOrEqualTo(3.0),
        );
        // The played length against the groove, and the groove's drawn
        // edge against the card the bar rides on.
        expect(contrast(scrub.played, scrub.groove), greaterThanOrEqualTo(3.0));
        expect(
          contrast(scrub.grooveBorder, scheme.surface),
          greaterThanOrEqualTo(3.0),
          reason:
              'groove edge vs card surface is '
              '${contrast(scrub.grooveBorder, scheme.surface).toStringAsFixed(2)}:1',
        );
      });
    }
  });

  // The tone objects are the contract, but only if the widgets actually
  // use them: pump one latched key and read the painted decoration back
  // out of the tree. One testWidgets per theme — the fork's MaterialApp
  // keeps its first resolved theme when its element survives across
  // pumpWidget calls, so the two themes never share a test.
  for (final brightness in Brightness.values) {
    testWidgets('the $brightness key paints its measured tones', (
      tester,
    ) async {
      final scheme = schemes[brightness]!;
      final tones = CassetteTones.of(scheme);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorSchemeSeed: const Color(0xFF4363D8)),
          darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF4363D8),
            brightness: Brightness.dark,
          ),
          themeMode: brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          home: Scaffold(
            body: CassetteKey(
              icon: const Icon(Icons.fiber_manual_record),
              label: 'REC',
              tooltip: 'REC',
              latched: true,
            ),
          ),
        ),
      );
      // Scoped to the key: MaterialApp internals carry their own
      // AnimatedContainers.
      final cap = tester.widget<AnimatedContainer>(
        find
            .descendant(
              of: find.byType(CassetteKey),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      final decoration = cap.decoration! as BoxDecoration;
      expect(decoration.gradient!.colors, tones.stops.sublist(2));
      expect(decoration.border!.top.color, tones.border);
    });
  }
}
