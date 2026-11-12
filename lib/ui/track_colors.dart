import 'package:flutter/material.dart';

/// Named tints for the fog-of-war exploration overlay. Keys persist in the
/// app settings (index.json); the values are the translucent overlay
/// colors actually drawn over the tiles. The transparency level is part
/// of the design: the map underneath must stay a legible, usable map.
const explorationTints = <String, Color>{
  'green': Color(0x334CAF50),
  'blue': Color(0x332196F3),
  'orange': Color(0x33FF9800),
  'purple': Color(0x339C27B0),
};

/// The tint a fresh install starts with (and the fallback for unknown
/// keys, so a hand-edited settings file can never break rendering).
const defaultTintKey = 'green';

/// The overlay color for a persisted tint key; unknown or missing keys
/// fall back to [defaultTintKey].
Color exploredAreaColor(String key) =>
    explorationTints[key] ?? explorationTints[defaultTintKey]!;
