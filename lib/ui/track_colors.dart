import 'package:flutter/material.dart';

/// Deterministic, distinct-enough palette for track polylines. Stable per
/// track id, so a track keeps its color across restarts.
const _palette = <Color>[
  Color(0xFFE6194B),
  Color(0xFF3CB44B),
  Color(0xFF4363D8),
  Color(0xFFF58231),
  Color(0xFF911EB4),
  Color(0xFF469990),
  Color(0xFF9A6324),
  Color(0xFF800000),
  Color(0xFF000075),
  Color(0xFF009E9E),
];

/// Color of the merged (single-polyline) rendering: one uniform color for
/// all tracks, so roads covered vs not covered by any track read at a
/// glance. Same value as the app's color scheme seed.
const mergedTrackColor = Color(0xFF4363D8);

Color colorForTrack(String id) {
  var v = 0;
  for (var i = 0; i < id.length; i++) {
    v = (v * 31 + id.codeUnitAt(i)) & 0x7FFFFFFF;
  }
  return _palette[v % _palette.length];
}
