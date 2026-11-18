/// Shared way-geometry math: meter-interval merging, meter cuts of a
/// way's geometry, point-to-geometry projection, and the unvisited-
/// stretches complement. The matcher (covered stretches) and the
/// unvisited-roads overlay (the view's dark remainder) are the same
/// arithmetic read in opposite directions, so both consume these
/// helpers instead of growing apart. Pure Dart, plain data in and out -
/// a future Rust core can reimplement the same contracts.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Meters per degree of latitude (WGS-84 mean) - the same constant the
/// matcher and the fog grid use.
const metersPerDegreeLat = 111320.0;

/// Sorts and merges overlapping meter intervals along a way: the union
/// of covered stretches, in order, touching intervals coalesced.
List<List<double>> mergeIntervals(List<List<double>> intervals) {
  if (intervals.isEmpty) return const [];
  final sorted = List.of(intervals)..sort((a, b) => a[0].compareTo(b[0]));
  final merged = <List<double>>[sorted.first];
  for (final interval in sorted.skip(1)) {
    final last = merged.last;
    if (interval[0] > last[1]) {
      merged.add(interval);
    } else if (interval[1] > last[1]) {
      last[1] = interval[1];
    }
  }
  return merged;
}

/// The way's points from [fromM] to [toM] meters along its geometry,
/// with interpolated endpoints where a cut falls inside a segment.
List<LatLng> cutGeometry(List<LatLng> pts, double fromM, double toM) {
  final out = <LatLng>[];
  var walked = 0.0;
  for (var i = 0; i + 1 < pts.length && walked < toM; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    final segLen = const Distance().distance(a, b);
    final segEnd = walked + segLen;
    if (segEnd > fromM && segLen > 0) {
      if (out.isEmpty) {
        out.add(fromM > walked ? _lerp(a, b, (fromM - walked) / segLen) : a);
      }
      out.add(toM < segEnd ? _lerp(a, b, (toM - walked) / segLen) : b);
    }
    walked = segEnd;
  }
  return out;
}

LatLng _lerp(LatLng a, LatLng b, double t) => LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t);

/// The distance in meters along [way] of the point of [way]'s geometry
/// nearest [p], and that nearest segment's index. A full scan per call:
/// ways are OSM-short and corridor points are walked per corridor, so a
/// hot start is premature; tolerance to a re-extracted geometry comes
/// from nearest-wins rather than an index-by-index assumption.
(double, int) offsetOf(List<LatLng> way, LatLng p) {
  final latRef = way.first.latitude * math.pi / 180;
  final lonScale = metersPerDegreeLat * math.cos(latRef);
  (double, double) toMeters(LatLng q) =>
      (q.longitude * lonScale, q.latitude * metersPerDegreeLat);
  final pm = toMeters(p);
  var best = (double.infinity, 0.0, 0); // dist2, offset, segment
  var offset = 0.0;
  for (var i = 0; i + 1 < way.length; i++) {
    final a = toMeters(way[i]);
    final b = toMeters(way[i + 1]);
    final len = math.sqrt((b.$1 - a.$1) * (b.$1 - a.$1) +
        (b.$2 - a.$2) * (b.$2 - a.$2));
    if (len > 0) {
      var t = ((pm.$1 - a.$1) * (b.$1 - a.$1) +
              (pm.$2 - a.$2) * (b.$2 - a.$2)) /
          (len * len);
      t = t.clamp(0.0, 1.0);
      final cx = a.$1 + t * (b.$1 - a.$1);
      final cy = a.$2 + t * (b.$2 - a.$2);
      final d2 = (pm.$1 - cx) * (pm.$1 - cx) + (pm.$2 - cy) * (pm.$2 - cy);
      if (d2 < best.$1) best = (d2, offset + t * len, i);
    }
    offset += len;
  }
  return (best.$2, best.$3);
}

/// The stretches of [way] no corridor in [corridors] covers: each
/// corridor projects to one merged meter interval (corridors are cut
/// from the way's own geometry, so their endpoints lie on the line and
/// a re-extract's drift lands on the nearest stretch), the intervals
/// merge, and the complement of `[0, way length]` comes back as
/// sub-polylines. Fully covered ways yield `const []`; so do ways too
/// short to draw.
List<List<LatLng>> unvisitedStretches(
    List<LatLng> way, List<List<LatLng>> corridors) {
  if (way.length < 2) return const [];
  final intervals = <List<double>>[];
  for (final corridor in corridors) {
    if (corridor.length < 2) continue;
    final a = offsetOf(way, corridor.first).$1;
    final b = offsetOf(way, corridor.last).$1;
    intervals.add(a <= b ? [a, b] : [b, a]);
  }
  final total = offsetOf(way, way.last).$1;
  if (total <= 0) return const [];
  // Complement of the merged intervals against [0, total]; the 0.5 m
  // epsilon keeps slivers at corridor seams out of the layer.
  const epsilon = 0.5;
  final stretches = <List<LatLng>>[];
  var cursor = 0.0;
  for (final interval in mergeIntervals(intervals)) {
    if (interval[0] > cursor + epsilon) {
      final s = cutGeometry(way, cursor, interval[0]);
      if (s.length > 1) stretches.add(s);
    }
    if (interval[1] > cursor) cursor = interval[1];
  }
  if (total > cursor + epsilon) {
    final s = cutGeometry(way, cursor, total);
    if (s.length > 1) stretches.add(s);
  }
  return stretches;
}
