import 'package:flutter/material.dart';

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

/// The ink hue the "ink" fog style draws with: a deep blue-black pen ink,
/// independent of the aggregate tints (ink reads as one hand across the
/// whole map, like a highlighter atlas drawn in one pen).
const inkHue = Color(0xFF1A237E);

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
