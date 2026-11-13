import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../ui/fog_of_war.dart' show unlockRadiusMeters;
import 'road_store.dart';

/// Meters per degree of latitude (WGS-84 mean) — the same constant
/// `fog_of_war.dart` uses for the unlock grid; kept local so the road
/// package stays self-contained.
const _metersPerDegreeLat = 111320.0;

/// The result of matching a track's unlock centers against a road store:
/// per way id, how much of its length the walking unlocked.
class RoadMatchResult {
  RoadMatchResult(this.matchedMeters, this.totalMeters);

  /// Matched corridor length per way id (the union of covered stretches,
  /// not a sum of overlaps), in meters.
  final Map<String, double> matchedMeters;

  /// Total geometry length per way id, in meters.
  final Map<String, double> totalMeters;

  /// Matched fraction of a way's length (0..1); ≥0.9 counts as a complete
  /// traversal (SPEC).
  double ratioFor(String wayId) {
    final total = totalMeters[wayId];
    if (total == null || total <= 0) return 0;
    return (matchedMeters[wayId] ?? 0) / total;
  }
}

/// The road-matching interface. Inputs and outputs are plain data (points
/// in, way ids + lengths out) so a future Rust core can implement the same
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

    for (final center in unlockCenters) {
      for (final way in _candidatesNear(center)) {
        final intervals =
            covered.putIfAbsent(way.id, () => []);
        _coverWay(center, way, intervals, totals);
      }
    }

    final matched = <String, double>{};
    covered.forEach((id, intervals) {
      // Only ways actually touched appear in the result: a candidate way
      // that never came within the radius (e.g. a parallel street in the
      // same bucket) unlocks nothing and must not be reported.
      if (intervals.isNotEmpty) matched[id] = _unionLength(intervals);
    });
    return RoadMatchResult(matched, totals);
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

    // Equirectangular meters relative to the segment midpoint latitude:
    // street-scale distortion is far below the radius tolerance.
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
      final segLen = math
          .sqrt(pow2(b.$1 - a.$1) + pow2(b.$2 - a.$2));
      if (segLen <= 0) continue; // degenerate duplicate point

      final vx = (b.$1 - a.$1) / segLen;
      final vy = (b.$2 - a.$2) / segLen;
      // Projection parameter of [p] onto the segment, clamped to it.
      var t = ((p.$1 - a.$1) * vx + (p.$2 - a.$2) * vy) / segLen;
      final clamped = t < 0 || t > 1;
      t = t.clamp(0.0, 1.0);
      final px = a.$1 + t * segLen * vx;
      final py = a.$2 + t * segLen * vy;
      final d = math.sqrt(pow2(p.$1 - px) + pow2(p.$2 - py));
      if (d < radiusMeters) {
        // Half-width of the circle's intersection with the segment line:
        // sqrt(r² − d²) meters along the segment around the projection.
        final half =
            math.sqrt(pow2(radiusMeters) - pow2(d)) / segLen;
        if (clamped) {
          // The circle touches the segment only at (or from) the endpoint:
          // cover from the endpoint inward.
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

  /// Total length of merged (non-overlapping) intervals.
  double _unionLength(List<List<double>> intervals) {
    if (intervals.isEmpty) return 0;
    intervals.sort((a, b) => a[0].compareTo(b[0]));
    var total = 0.0;
    var curStart = intervals.first[0];
    var curEnd = intervals.first[1];
    for (final interval in intervals.skip(1)) {
      if (interval[0] > curEnd) {
        total += curEnd - curStart;
        curStart = interval[0];
        curEnd = interval[1];
      } else if (interval[1] > curEnd) {
        curEnd = interval[1];
      }
    }
    return total + curEnd - curStart;
  }
}

double pow2(double x) => x * x;
