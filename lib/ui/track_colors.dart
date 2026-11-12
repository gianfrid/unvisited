import 'package:flutter/material.dart';

/// Translucent tint of the fog-of-war exploration overlay: every track
/// point unlocks a circular area around it, drawn over the OSM tiles in
/// this single color. Per-track polylines and their palette are gone — the
/// unlocked overlay is the point of the app now — so the tint must stay
/// light enough that the map underneath remains a legible, usable map.
const exploredAreaColor = Color(0x334CAF50);
