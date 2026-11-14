import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../ui/fog_of_war.dart' show unlockRadiusMeters;
import 'road_format.dart';
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

/// How much closer a rival way must be than the active one before an unlock
/// center switches attribution. Wide enough to absorb GPS wobble between
/// parallel ways (the measured hops sit at sub-5 m distance differences),
/// small enough that genuinely moving onto another way (on-centerline, or a
/// mid-block crossing) switches immediately.
const switchMarginMeters = 5.0;

/// Geometric matcher: every unlock center lights the road geometry within
/// the unlock radius; the covered stretches accumulate per way.
///
/// This is deliberately not a Hidden-Markov map matcher (research report,
/// finding 1): the goal is "which road did the user touch", not "reconstruct
/// the exact driven route", so there is no routing graph, no timestamps, no
/// state machine — and a parallel service road over-unlocking is accepted as
/// cosmetic, the same false positive the 15 m unlock circles already have.
///
/// Attribution (hybrid scoring, slice 7): each center's coverage goes to one
/// way — the way matched at the previous center, as long as it stays within
/// [switchMarginMeters] of the nearest candidate, otherwise the nearest way.
/// Real tracks wobble sub-radius distances between parallel ways at every
/// ambiguous point (measured: 17.6% of points across 24 real recordings,
/// 401 attribution hops), which would otherwise split matched lengths and
/// let an un-ridden parallel way complete on wobble alone. Rival ways keep
/// their own covered-stretch accounting untouched; what changes is only
/// which way a given center's neighborhood is credited to.
///
/// Performance: the store's z12 buckets are far too coarse to query per
/// point (a whole mid-sized city fits in a handful of them, so bucket
/// queries degenerate to "every way"), so the matcher builds its own
/// segment-level hash index at radius-scale cells (see [_SegmentIndex]).
/// Index build decodes every way once (city scale: a few hundred ms, tens
/// of MB) and is lazy — the first match pays it, not app startup.
class GeometricRoadMatcher extends RoadMatcher {
  GeometricRoadMatcher(this._store, {double? radiusMeters})
      : radiusMeters = radiusMeters ?? unlockRadiusMeters;

  final RoadStore _store;

  /// Corridor radius around an unlock center that unlocks road geometry.
  final double radiusMeters;

  _SegmentIndex? _index;

  /// Builds the segment index on first use; exposed so tools can pre-pay it
  /// and measure it separately from matching.
  void ensureIndex() => _index ??= _SegmentIndex(_store, radiusMeters * 4);

  @override
  RoadMatchResult match(Iterable<LatLng> unlockCenters) {
    ensureIndex();
    final index = _index!;
    // way id → covered intervals (start, end) in meters along the way.
    final covered = <String, List<List<double>>>{};
    String? active;
    for (final center in unlockCenters) {
      final candidates = index.segmentsNear(center, radiusMeters);

      // Nearest distance per candidate way; the nearest way id overall.
      final dists = <String, double>{};
      var best = '';
      var bestDist = double.infinity;
      for (final seg in candidates) {
        final d = seg.distanceTo(center);
        if (d < (dists[seg.wayId] ?? double.infinity)) {
          dists[seg.wayId] = d;
        }
        if (d < bestDist) {
          bestDist = d;
          best = seg.wayId;
        }
      }

      // Stickiness: the active way keeps attribution unless the nearest
      // rival is closer by more than [switchMarginMeters].
      var chosen = best;
      if (active != null) {
        final activeDist = dists[active];
        if (activeDist != null && activeDist <= bestDist + switchMarginMeters) {
          chosen = active;
        }
      }
      active = chosen;

      for (final seg in candidates) {
        if (seg.wayId == chosen) {
          _coverSegment(center, seg, covered.putIfAbsent(chosen, () => []));
        }
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
          _cut(index.geometry[id]!, interval[0], interval[1]),
      ];
    });
    return RoadMatchResult(matched, index.totals, corridors);
  }

  /// Extends [intervals] (meters along the way) with the stretch of [seg]
  /// within the radius of [center].
  void _coverSegment(
      LatLng center, _Segment seg, List<List<double>> intervals) {
    final p = seg.toMeters(center);
    final a = seg.aM;
    final b = seg.bM;
    final segLen = seg.length;
    final vx = (b.$1 - a.$1) / segLen;
    final vy = (b.$2 - a.$2) / segLen;
    // Projection parameter of [p] onto the segment, clamped to it.
    var t = ((p.$1 - a.$1) * vx + (p.$2 - a.$2) * vy) / segLen;
    final clamped = t < 0 || t > 1;
    t = t.clamp(0.0, 1.0);
    final px = a.$1 + t * segLen * vx;
    final py = a.$2 + t * segLen * vy;
    final d = math.sqrt(_pow2(p.$1 - px) + _pow2(p.$2 - py));
    if (d >= radiusMeters) return;
    // Half-width of the circle's intersection with the segment line:
    // sqrt(r² − d²) meters along the segment around the projection.
    final half = math.sqrt(_pow2(radiusMeters) - _pow2(d)) / segLen;
    if (clamped) {
      // The circle touches the segment only at (or from) an endpoint:
      // cover from that endpoint inward.
      if (t == 0) {
        intervals.add([seg.offset, seg.offset + half * segLen]);
      } else {
        intervals.add([seg.offset + (1 - half) * segLen, seg.end]);
      }
    } else {
      intervals.add([
        seg.offset + (t - half).clamp(0.0, 1.0) * segLen,
        seg.offset + (t + half).clamp(0.0, 1.0) * segLen,
      ]);
    }
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
          out.add(fromM > walked ? _lerp(a, b, (fromM - walked) / segLen) : a);
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

/// One pre-projected segment: endpoints in equirectangular meters, its
/// offset/end in meters along the parent way, and its parent way id.
class _Segment {
  _Segment(this.wayId, this.offset, this.end, this.aM, this.bM, this.length,
      this._latRefRad);

  final String wayId;
  final double offset;
  final double end;
  final (double, double) aM;
  final (double, double) bM;
  final double length;
  /// Reference latitude (radians) for the equirectangular projection.
  final double _latRefRad;

  (double, double) toMeters(LatLng p) => (
        p.longitude * _metersPerDegreeLat * math.cos(_latRefRad),
        p.latitude * _metersPerDegreeLat,
      );

  /// Meters from [p] to this segment: the clamped projection's distance,
  /// the candidate distance the attribution rule compares across ways.
  double distanceTo(LatLng p) {
    final pm = toMeters(p);
    final len = length;
    var t = len == 0
        ? 0.0
        : ((pm.$1 - aM.$1) * (bM.$1 - aM.$1) +
                (pm.$2 - aM.$2) * (bM.$2 - aM.$2)) /
            (len * len);
    t = t.clamp(0.0, 1.0);
    final cx = aM.$1 + t * (bM.$1 - aM.$1);
    final cy = aM.$2 + t * (bM.$2 - aM.$2);
    return math.sqrt(_pow2(pm.$1 - cx) + _pow2(pm.$2 - cy));
  }
}

/// Segment-level spatial hash index, built lazily per z12 bucket.
///
/// The store's z12 buckets are the unit of loading: indexing a bucket decodes
/// only that bucket's ways, so a track costs work proportional to the area it
/// covers, not to the size of the region file (a Germany-sized file indexes
/// the same few buckets a Berlin walk touches). Cells are radius-scale, so a
/// point query reads a 3×3 neighborhood — a handful of segments — instead of
/// every way in the bucket.
class _SegmentIndex {
  _SegmentIndex(this._store, double cellMeters) : cellSize = cellMeters {
    // Longitude cells use a fixed reference latitude (the first way's start):
    // region-scale consistency is all that is needed, and registration is
    // conservative (a segment registers in every cell its bbox touches).
    final refLat = _refLat(_store);
    _dLatCell = cellSize / _metersPerDegreeLat;
    _dLonCell = _dLatCell / math.cos(refLat * math.pi / 180);
    _refLatRad = refLat * math.pi / 180;
  }

  final RoadStore _store;
  final double cellSize;
  late final double _dLatCell;
  late final double _dLonCell;
  late final double _refLatRad;

  final Map<(int, int), List<_Segment>> _cells = {};

  /// Buckets already folded into the index.
  final Set<String> _indexedBuckets = {};

  /// Decoded geometry per indexed way id.
  final Map<String, List<LatLng>> geometry = {};

  /// Total geometry length per indexed way id.
  final Map<String, double> totals = {};

  /// Segments within [radius] of [p], indexing whatever buckets the 3×3 cell
  /// neighborhood could reach first (usually just the point's own bucket).
  Iterable<_Segment> segmentsNear(LatLng p, double radius) {
    final x = (p.longitude / _dLonCell).floor();
    final y = (p.latitude / _dLatCell).floor();
    // The 3×3 cells span at most two z12 tiles per axis; ensure each is
    // indexed (the 8 offsets normally resolve to the point's own bucket).
    _ensureIndexedAt(p);
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        _ensureIndexedAt(LatLng(p.latitude + dy * _dLatCell,
            p.longitude + dx * _dLonCell));
      }
    }
    return [
      for (var dx = -1; dx <= 1; dx++)
        for (var dy = -1; dy <= 1; dy++)
          ...?_cells[(x + dx, y + dy)],
    ];
  }

  void _ensureIndexedAt(LatLng p) {
    final key = roadBucketKeyFor(p.latitude, p.longitude);
    if (!_indexedBuckets.add(key)) return;
    for (final way in _store.bucketByKey(key)) {
      _indexWay(way);
    }
  }

  void _indexWay(RoadWay way) {
    if (geometry.containsKey(way.id)) return;
    final pts = way.points;
    if (pts.length < 2) return;
    geometry[way.id] = pts;
    (double, double) toMeters(LatLng p) => (
          p.longitude * _metersPerDegreeLat * math.cos(_refLatRad),
          p.latitude * _metersPerDegreeLat,
        );
    var offset = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      final aM = toMeters(pts[i]);
      final bM = toMeters(pts[i + 1]);
      final len = math.sqrt(_pow2(bM.$1 - aM.$1) + _pow2(bM.$2 - aM.$2));
      if (len <= 0) continue;
      final seg = _Segment(way.id, offset, offset + len, aM, bM, len, _refLatRad);
      offset += len;
      // Every cell the segment's bbox touches; the query's 3×3 neighborhood
      // plus this conservative registration covers the radius.
      final x0 =
          (math.min(pts[i].longitude, pts[i + 1].longitude) / _dLonCell).floor();
      final x1 =
          (math.max(pts[i].longitude, pts[i + 1].longitude) / _dLonCell).floor();
      final y0 =
          (math.min(pts[i].latitude, pts[i + 1].latitude) / _dLatCell).floor();
      final y1 =
          (math.max(pts[i].latitude, pts[i + 1].latitude) / _dLatCell).floor();
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          _cells.putIfAbsent((x, y), () => []).add(seg);
        }
      }
    }
    totals[way.id] = offset;
  }

  /// Reference latitude for the longitude cell width: the first way's first
  /// point of the first bucket (any point in the region works at region
  /// scale). Only that one bucket is parsed — opening a region file must not
  /// cost a full scan.
  static double _refLat(RoadStore store) {
    for (final key in store.bucketKeys) {
      for (final way in store.bucketByKey(key)) {
        if (way.points.isNotEmpty) return way.points.first.latitude;
      }
    }
    return 0;
  }
}
