import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../geo.dart' show initialBearingDeg;

/// Pure-Dart perpendicular lane offsetting for the member-picking overlay:
/// shifts a polyline sideways by [offsetMeters] (signed — negative offsets
/// to the other side of the travel direction) so overlapping member tracks
/// render as parallel lanes with their own hover/tap space. No Flutter
/// imports, so the math stays unit-testable.
///
/// Each vertex is pushed along the average of its adjacent segments'
/// perpendiculars (endpoints use their single segment's perpendicular), so
/// corners stay equidistant from both sides; a degenerate (zero-length)
/// segment borrows the previous direction. The offset is a ground-meter
/// shift applied as a destination point from the vertex along the
/// perpendicular bearing, which keeps lane spacing visually constant at
/// every latitude.
List<LatLng> offsetLanePoints(List<LatLng> points, double offsetMeters) {
  if (points.length < 2 || offsetMeters == 0) return List.of(points);

  // Per-segment travel bearings; a degenerate segment reuses the last
  // good one (a zero-length segment has no direction of its own).
  final bearings = <double>[];
  var last = 0.0;
  for (var i = 0; i < points.length - 1; i++) {
    final a = points[i], b = points[i + 1];
    if (a.latitude == b.latitude && a.longitude == b.longitude) {
      bearings.add(last);
    } else {
      last = initialBearingDeg(
          a.latitude, a.longitude, b.latitude, b.longitude);
      bearings.add(last);
    }
  }

  // Perpendicular bearing of each vertex: the average of the two adjacent
  // segments' perpendiculars (endpoints: the single one). Averaging two
  // bearings must go through unit vectors — a plain mean of angles would
  // fold across the 0/360 wrap.
  double perpendicularOf(double segmentBearing) =>
      (segmentBearing + 90) % 360;

  LatLng shift(LatLng p, double bearingDeg) {
    final rad = math.pi / 180;
    final dLat = offsetMeters * math.cos(bearingDeg * rad);
    final dLon = offsetMeters *
        math.sin(bearingDeg * rad) /
        math.max(math.cos(p.latitude * rad), 0.01);
    // 111320 m per degree of latitude, as in the aggregate grid.
    return LatLng(
      p.latitude + dLat / 111320.0,
      p.longitude + dLon / 111320.0,
    );
  }

  final out = <LatLng>[];
  for (var i = 0; i < points.length; i++) {
    final incoming = i > 0 ? perpendicularOf(bearings[i - 1]) : null;
    final outgoing =
        i < bearings.length ? perpendicularOf(bearings[i]) : null;
    double bearing;
    if (incoming != null && outgoing != null) {
      final ix = math.cos(incoming * math.pi / 180) +
          math.cos(outgoing * math.pi / 180);
      final iy = math.sin(incoming * math.pi / 180) +
          math.sin(outgoing * math.pi / 180);
      bearing = (math.atan2(iy, ix) / math.pi * 180 + 360) % 360;
    } else {
      bearing = (incoming ?? outgoing)!;
    }
    out.add(shift(points[i], bearing));
  }
  return out;
}
