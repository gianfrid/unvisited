import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../geo.dart' show haversineMeters, initialBearingDeg;

/// Pure-Dart lane offsetting for the member-picking overlay: shifts a
/// polyline sideways so overlapping member tracks render as parallel
/// lanes with their own hover/tap space. No Flutter imports, so the math
/// stays unit-testable.
///
/// Offsets are per-vertex and adaptive (see [laneOffsetsPerVertex]): a
/// track that is alone at a vertex sits on its true geometry (offset 0);
/// only where members actually overlap do they spread sideways. Each
/// vertex is pushed along the average of its adjacent segments'
/// perpendiculars (endpoints use their single segment's perpendicular), so
/// corners stay equidistant from both sides; a degenerate (zero-length)
/// segment borrows the previous direction. Offsets are ground meters,
/// applied as a destination shift along the perpendicular bearing, which
/// keeps lane spacing visually constant at every latitude.

/// Constant-offset convenience: shifts every vertex by [offsetMeters].
List<LatLng> offsetLanePoints(List<LatLng> points, double offsetMeters) =>
    offsetLanePointsPerVertex(
        points, List<double>.filled(points.length, offsetMeters));

/// Shifts each vertex of [points] sideways by its own entry in
/// [offsetsMeters] (same length as [points]).
List<LatLng> offsetLanePointsPerVertex(
    List<LatLng> points, List<double> offsetsMeters) {
  if (points.length < 2 || offsetsMeters.length != points.length) {
    return List.of(points);
  }
  if (offsetsMeters.every((o) => o == 0)) return List.of(points);

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

  LatLng shift(LatLng p, double bearingDeg, double meters) {
    final rad = math.pi / 180;
    final dLat = meters * math.cos(bearingDeg * rad);
    final dLon = meters *
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
    out.add(shift(points[i], bearing, offsetsMeters[i]));
  }
  return out;
}

/// Per-vertex lane offsets for one member track: where only that member
/// passes, the offset is 0 (the track stays on its true geometry, over
/// its fog corridor); where several members overlap, they spread
/// symmetrically around the true geometry — `(rank - (count-1)/2) *
/// laneMeters`, ranks taken in member order (which the caller keeps in
/// lane order, so the stacking is stable).
///
/// [membersPoints] holds every member's points (the same decimation the
/// renderer draws); [selfIndex] is this track's index in it. Overlap is
/// decided against a grid of all members' points (cell edge =
/// [overlapMeters], longitude cells scaled by cos(latitude), each
/// neighboring cell pair scanned once, degree-space reject before the
/// haversine), so the cost is O(points), not O(n²) pairwise.
List<double> laneOffsetsPerVertex(
  List<LatLng> points, {
  required int selfIndex,
  required List<List<LatLng>> membersPoints,
  required double laneMeters,
  required double overlapMeters,
}) {
  if (points.isEmpty) return const [];
  if (membersPoints.length <= 1) {
    return List<double>.filled(points.length, 0.0);
  }

  const metersPerDegLat = 111320.0;
  final latCellDeg = overlapMeters / metersPerDegLat;
  final cells = <String, Map<int, List<LatLng>>>{};
  for (var m = 0; m < membersPoints.length; m++) {
    for (final p in membersPoints[m]) {
      final cx = (p.latitude / latCellDeg).floor();
      final cy = (p.longitude /
              (overlapMeters / (metersPerDegLat * _cosLat(p.latitude))))
          .floor();
      cells
          .putIfAbsent('$cx,$cy', () => <int, List<LatLng>>{})
          .putIfAbsent(m, () => <LatLng>[])
          .add(p);
    }
  }

  final out = <double>[];
  for (final p in points) {
    final cx = (p.latitude / latCellDeg).floor();
    final cy = (p.longitude /
            (overlapMeters / (metersPerDegLat * _cosLat(p.latitude))))
        .floor();
    final lonBound = latCellDeg / _cosLat(p.latitude);
    final present = <int>{};
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        final cell = cells['${cx + dx},${cy + dy}'];
        if (cell == null) continue;
        for (final entry in cell.entries) {
          for (final q in entry.value) {
            if ((q.latitude - p.latitude).abs() > latCellDeg) continue;
            if ((q.longitude - p.longitude).abs() > lonBound) continue;
            if (haversineMeters(
                    p.latitude, p.longitude, q.latitude, q.longitude) <=
                overlapMeters) {
              present.add(entry.key);
              break; // one nearby point of a member is enough
            }
          }
        }
      }
    }
    final sorted = present.toList()..sort();
    final rank = sorted.indexOf(selfIndex);
    final count = sorted.length;
    out.add(rank < 0 ? 0.0 : (rank - (count - 1) / 2) * laneMeters);
  }
  return out;
}

double _cosLat(double lat) {
  // Longitude cells shrink with the cosine of the latitude; floor near
  // the poles so the grid stays finite.
  return math.max(math.cos(lat * math.pi / 180), 0.01);
}
