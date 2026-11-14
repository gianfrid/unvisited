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

/// The solid counterparts for the recording trace, which draws at its own
/// alpha; unknown keys fall back to the recording default.
Color recordingTraceColor(String key) =>
    explorationTints[key]?.withValues(alpha: 0.65) ??
    explorationTints[defaultRecordingTintKey]!.withValues(alpha: 0.65);
