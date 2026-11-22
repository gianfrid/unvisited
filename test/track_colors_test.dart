import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/ui/track_colors.dart';

void main() {
  test('inkColorFor is opaque and distinct per tint', () {
    final colors = {
      for (final key in explorationTints.keys) inkColorFor(key),
    };
    expect(colors.length, explorationTints.length,
        reason: 'each aggregate tint must yield its own ink colour');
    for (final c in colors) {
      expect(c.a, 1.0, reason: 'ink strokes draw opaque per pass alpha');
    }
  });

  test('inkColorFor is a dark blend of the tint toward the ink hue', () {
    for (final entry in explorationTints.entries) {
      final ink = inkColorFor(entry.key);
      final base = entry.value.withValues(alpha: 1);
      // Darker than the source tint: the blend pulls toward the ink hue.
      expect(ink.computeLuminance(), lessThan(base.computeLuminance()));
    }
  });

  test('inkColorFor falls back to the default tint for unknown keys', () {
    expect(inkColorFor('no-such-tint'), inkColorFor(defaultTintKey));
  });
}
