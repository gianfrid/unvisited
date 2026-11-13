import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../ui/fog_of_war.dart' show unlockRadiusMeters;
import 'road_store.dart';

/// Meters per degree of latitude (WGS-84 mean) — the same constant
/// `fog_of_war.dart` uses for the unlock grid; kept local so the road
/// package stays self-contained.
const _metersPerDegreeLat = 111320.0;

/// The result of matching a track's unlock centers against a road store.
class RoadMatchResult {
  RoadMatchResult(this.matchedMeters, this.totalMeters, this.corridors);

  /// Matched corridor length per way id (the union of covered stretches,
  /// not a sum of overlaps), in meters.
  final Map<String, double> matchedMeters;

  /// Total geometry length per way id, in meters.
  final Map<String, double> totalMeters;

  /// The matched sub-polylines per way id — the corridor actually walked,
  /// cut out of the way's geometry at the covered stretches. These are what
  /// gets persisted and rendered; matched lengths alone could not render an
  /// honest corridor (a way touched at one end must not light up fully).
  final Map<String, List<List<LatLng>>> corridors;

  /// Matched fraction of a way's length (0..1); ≥0.9 counts as a complete
  /// traversal (SPEC).
  double ratioFor(String wayId) {
    final total = totalMeters[wayId];
    if (total == null || total <= 0) return 0;
    return (matchedMeters[wayId] ?? 0) / total;
  }
}

/// The road-matching interface. Inputs and outputs are plain data (points
/// in, way ids + geometry out) so a future Rust core can implement the same
/// contract behind FFI without the boundary ever leaking Dart objects.
abstract class RoadMatcher {
  RoadMatchResult match(Iterable<LatLng> unlockCenters);
}

/// Geometric matcher: every unlock center lights the road geometry within
/// the unlock radius; the covered stretches accumulate per way.
///
/// This is deliberately not a Hidden-Markov map matcher (research report,
/// finding 1): the goal is "which road did the user touch", not "reconstruct
/// the exact driven route", so there is no routing graph, no timestamps, no
/// state machine — and a parallel service road over-unlocking is accepted as
/// cosmetic, the same false positive the 15 m unlock circles already have.
class GeometricRoadMatcher extends RoadMatcher {
  GeometricRoadMatcher(this._store, {double? radiusMeters})
      : radiusMeters = radiusMeters ?? unlockRadiusMeters;

  final RoadStore _store;

  /// Corridor radius around an unlock center that unlocks road geometry.
  final double radiusMeters;

  @override
  RoadMatchResult match(Iterable<LatLng> unlockCenters) {
    // way id → covered intervals (start, end) in meters along the way.
    final covered = <String, List<List<double>>>{};
    final totals = <String, double>{};
    final ways = <String, RoadWay>{};

    for (final center in unlockCenters) {
      for (final way in _candidatesNear(center)) {
        ways[way.id] = way;
        _coverWay(center, way, covered.putIfAbsent(way.id, () => []),
            totals);
      }
    }

    final matched = <String, double>{};
    final corridors = <String, List<List<LatLng>>>{};
    covered.forEach((id, intervals) {
      // Only ways actually touched appear in the result: a candidate way
      // that never came within the radius (e.g. a parallel street in the
      // same bucket) unlocks nothing and must not be reported.
      if (intervals.isEmpty) return;
      final merged = _merge(intervals);
      matched[id] = _spanLength(merged);
      corridors[id] = [
        // One corridor polyline per merged covered stretch — cutting each
        // interval separately keeps disjoint stretches disjoint (a way
        // visited at both ends shows two lit pieces, not a lit gap).
        for (final interval in merged)
          _cut(_store.decodedPoints(ways[id]!), interval[0], interval[1]),
      ];
    });
    return RoadMatchResult(matched, totals, corridors);
  }

  /// Ways near [center]: the containing z12 bucket plus its 8 neighbors, so
  /// a point just short of a tile edge still sees ways across it.
  Iterable<RoadWay> _candidatesNear(LatLng center) {
    final seen = <String, RoadWay>{};
    for (final key in _store.bucketKeysNear(center.latitude, center.longitude)) {
      for (final way in _store.bucketByKey(key)) {
        seen[way.id] = way;
      }
    }
    return seen.values;
  }

  /// Extends [intervals] (meters along the way) with the stretch of the way
  /// within the radius of [center], and maintains [totals].
  void _coverWay(LatLng center, RoadWay way, List<List<double>> intervals,
      Map<String, double> totals) {
    final pts = _store.decodedPoints(way);
    if (pts.length < 2) return;

    // Equirectangular meters relative to the way's first point: street-scale
    // distortion is far below the radius tolerance.
    final metersRef = pts.first;
    (double, double) toMeters(LatLng p) => (
          p.longitude * _metersPerDegreeLat *
              math.cos(metersRef.latitude * math.pi / 180),
          p.latitude * _metersPerDegreeLat,
        );

    final p = toMeters(center);
    var walked = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = toMeters(pts[i]);
      final b = toMeters(pts[i + 1]);
      final segLen = math.sqrt(_pow2(b.$1 - a.$1) + _pow2(b.$2 - a.$2));
      if (segLen <= 0) continue; // degenerate duplicate point

      final vx = (b.$1 - a.$1) / segLen;
      final vy = (b.$2 - a.$2) / segLen;
      // Projection parameter of [p] onto the segment, clamped to it.
      var t = ((p.$1 - a.$1) * vx + (p.$2 - a.$2) * vy) / segLen;
      final clamped = t < 0 || t > 1;
      t = t.clamp(0.0, 1.0);
      final px = a.$1 + t * segLen * vx;
      final py = a.$2 + t * segLen * vy;
      final d = math.sqrt(_pow2(p.$1 - px) + _pow2(p.$2 - py));
      if (d < radiusMeters) {
        // Half-width of the circle's intersection with the segment line:
        // sqrt(r² − d²) meters along the segment around the projection.
        final half = math.sqrt(_pow2(radiusMeters) - _pow2(d)) / segLen;
        if (clamped) {
          // The circle touches the segment only at (or from) an endpoint:
          // cover from that endpoint inward.
          if (t == 0) {
            intervals.add([walked, walked + half * segLen]);
          } else {
            intervals.add([walked + (1 - half) * segLen, walked + segLen]);
          }
        } else {
          intervals.add([
            walked + (t - half).clamp(0.0, 1.0) * segLen,
            walked + (t + half).clamp(0.0, 1.0) * segLen,
          ]);
        }
      }
      walked += segLen;
    }
    totals[way.id] = walked;
  }

  /// Sorts and merges overlapping meter intervals along a way.
  List<List<double>> _merge(List<List<double>> intervals) {
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

  double _spanLength(List<List<double>> merged) =>
      merged.fold(0.0, (sum, i) => sum + (i[1] - i[0]));

  /// The way's points from [fromM] to [toM] meters along its geometry, with
  /// interpolated endpoints where the cut falls inside a segment.
  List<LatLng> _cut(List<LatLng> pts, double fromM, double toM) {
    final out = <LatLng>[];
    var walked = 0.0;
    for (var i = 0; i + 1 < pts.length && walked < toM; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final segLen = const Distance().distance(a, b);
      final segEnd = walked + segLen;
      if (segEnd > fromM && segLen > 0) {
        // Start: interpolated when the cut opens inside this segment,
        // otherwise the segment's own start point.
        if (out.isEmpty) {
          out.add(fromM > walked
              ? _lerp(a, b, (fromM - walked) / segLen)
              : a);
        }
        // End: interpolated when the cut closes inside this segment,
        // otherwise the segment's own end point.
        out.add(toM < segEnd ? _lerp(a, b, (toM - walked) / segLen) : b);
      }
      walked = segEnd;
    }
    return out;
  }

  static LatLng _lerp(LatLng a, LatLng b, double t) => LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t);
}

double _pow2(double x) => x * x;
