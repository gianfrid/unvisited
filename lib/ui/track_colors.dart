import 'package:material_ui/material_ui.dart';

/// Named tints for the map overlay colors. Keys persist in the app
/// settings (index.json); the values are the translucent overlay colors
/// actually drawn over the tiles. The transparency level is part of the
/// design: the map underneath must stay a legible, usable map.
///
/// The first entry is the main fog aggregate's fixed default; the rest are
/// the colors the other aggregates cycle through (per-aggregate overrides
/// take precedence — see the aggregate selection).
const explorationTints = <String, Color>{
  'green': Color(0x334CAF50),
  'blue': Color(0x332196F3),
  'orange': Color(0x33FF9800),
  'purple': Color(0x339C27B0),
  'red': Color(0x33F44336),
  'teal': Color(0x33009688),
  'amber': Color(0x33FFC107),
  'pink': Color(0x33E91E63),
};

/// The tint a fresh install starts with (and the fallback for unknown
/// keys, so a hand-edited settings file can never break rendering).
const defaultTintKey = 'green';

/// The recording trace's default tint (the Settings "trace color" row
/// drives it; unknown keys fall back here).
const defaultRecordingTintKey = 'red';

/// The overlay color for a persisted tint key; unknown or missing keys
/// fall back to [defaultTintKey].
Color exploredAreaColor(String key) =>
    explorationTints[key] ?? explorationTints[defaultTintKey]!;

/// The ink hue the "ink" trace style blends toward: a deep blue-black pen
/// ink. Not drawn directly — see [inkColorFor], which derives the stroke
/// colour from the aggregate's tint so the multitrack colour edit applies
/// in ink mode too.
const inkHue = Color(0xFF1A237E);

/// The stroke colour of the "ink" trace style for a tint key: the tint at
/// full opacity blended ~55% toward the deep [inkHue], so the stroke keeps
/// the aggregate's hue (distinct aggregates stay distinct) while staying
/// dark enough to read as pen ink over the tiles. Unknown keys fall back
/// like [exploredAreaColor].
Color inkColorFor(String key) {
  final base = (explorationTints[key] ?? explorationTints[defaultTintKey]!)
      .withValues(alpha: 1);
  return Color.alphaBlend(inkHue.withValues(alpha: 0.55), base);
}

/// Per-pass opacities of the ink style, bleed first (the wide pass under
/// the core reads faintest); the core pass lands near-opaque.
const inkPassAlphas = <double>[0.25, 0.6, 0.9];

/// Per-pass relative widths of the ink style, multiplied by the polyline
/// style's stroke width; bleed widest, core narrowest.
const inkPassWidthFactors = <double>[2.2, 1.4, 0.7];

/// The solid counterparts for the recording trace, which draws at its own
/// alpha; unknown keys fall back to the recording default.
Color recordingTraceColor(String key) =>
    explorationTints[key]?.withValues(alpha: 0.65) ??
    explorationTints[defaultRecordingTintKey]!.withValues(alpha: 0.65);
