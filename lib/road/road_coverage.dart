/// The viewport's answer to "how much road around here is still
/// unvisited", computed from the active road region and the tracks'
/// persisted unlock state.
///
/// The number is length-weighted: sum the way totals across the z12
/// buckets the camera bound spans, subtract what the persisted corridors
/// cover, and report the unvisited share - in meters, not by way count,
/// because a trunk road is worth more than two footways. This is the
/// chip's data feed and the foundation the unvisited-roads overlay
/// (backlog item 2) extends into geometry.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'road_format.dart';
import 'road_store.dart';
import 'way_geometry.dart';

/// One viewport way's still-unmatched geometry: the way's id (stable
/// across re-extracts) and the sub-polylines no corridor covers — the
/// dark remainder the unvisited-roads overlay draws.
typedef OverlayWay = (String id, List<List<LatLng>> stretches);

/// The viewport's covered/total road question, answered in meters.
class CoverageReport {
  const CoverageReport({
    required this.totalMeters,
    required this.matchedMeters,
    required this.wayCount,
    required this.bucketCount,
  });

  /// Sum of every viewport way's geometry length, meters.
  final double totalMeters;

  /// Sum of the ways' covered spans, meters (per-way capped at total).
  final double matchedMeters;

  /// Ways in the viewport's buckets.
  final int wayCount;

  /// Buckets that contributed ways.
  final int bucketCount;

  /// The unvisited share of the view's road network (0..1); 0.0 when
  /// the view has no roads at all - callers show nothing rather than
  /// report "100% unvisited" over open water.
  double get unvisitedRatio {
    if (totalMeters <= 0) return 0;
    var covered = matchedMeters / totalMeters;
    if (covered > 1) covered = 1;
    if (covered < 0) covered = 0;
    return 1 - covered;
  }
}

/// Aggregates viewport roads against all tracks' unlock state.
///
/// Per-bucket way totals are decoded once per bucket and kept in an LRU
/// of way-id-to-length maps - scalars only, never geometry, so the
/// worst case is tens of MB of maps, not decoded polylines. Reports are
/// memoized by viewport tile rectangle plus unlock epoch, so follow-
/// camera re-centers at an unchanged rectangle skip all work.
class ViewportCoverage {
  ViewportCoverage(this._store,
      {this.maxTilesPerAxis = 6, this.overlayMaxTiles = 3,
       this.maxCachedBuckets = 64});

  final RoadStore _store;

  /// The zoom floor: viewports spanning more z12 tiles per axis than
  /// this report nothing - whole-region compute is seconds even on
  /// desktop, and the share is meaningless at that zoom anyway.
  final int maxTilesPerAxis;

  /// The overlay's floor, tighter than the chip's: drawing every
  /// unmatched way across a 6x6-tile city view is dense noise, so the
  /// dashed layer only renders when the viewport spans at most this
  /// many z12 tiles per axis. The chip keeps its wider floor.
  final int overlayMaxTiles;

  final int maxCachedBuckets;

  /// Bucket key to way-id-to-geometry-length (meters), decoded lazily.
  final Map<String, Map<String, double>> _totals = {};

  /// LRU order over [_totals]' keys, oldest first.
  final List<String> _lru = [];

  String? _lastRectangle;

  int _corridorVersion = 0;

  int _computedAtVersion = -1;

  CoverageReport? _lastReport;

  /// Drop memoized reports - unlock data changed, so an unchanged
  /// viewport still needs a fresh answer.
  void invalidate() {
    _corridorVersion++;
    _lastReport = null;
    _lastOverlay = const [];
  }

  String? _lastOverlayRectangle;

  int _computedOverlayAtVersion = -1;

  List<OverlayWay> _lastOverlay = const [];

  /// The still-unvisited stretches of every way in the viewport, for
  /// the dashed overlay layer (see [coverage] for the corner semantics
  /// and the corridor merge). Geometry reads go through the store's own
  /// bucket LRU: one transient decode per settle, no second geometry
  /// cache here. Ways fully covered by some corridor draw nothing, so
  /// they stay out. Below the [overlayMaxTiles] floor the list is
  /// empty - the chip keeps the wider view, the overlay abstains.
  Future<List<OverlayWay>> unvisitedIn(
    LatLng southWest,
    LatLng northEast,
    Map<String, List<List<LatLng>>> corridorsByWay,
  ) async {
    final rectangle = _rectangleFor(southWest, northEast,
        maxTiles: overlayMaxTiles);
    if (rectangle == null) {
      if (identical(_lastOverlay, const [])) return _lastOverlay;
      _lastOverlay = const [];
      _lastOverlayRectangle = null;
      return _lastOverlay;
    }
    final (x0, y0, x1, y1) = rectangle;
    final memoKey = '$x0,$y0,$x1,$y1';
    if (memoKey == _lastOverlayRectangle &&
        _computedOverlayAtVersion == _corridorVersion) {
      return _lastOverlay;
    }
    _lastOverlayRectangle = memoKey;

    // Multi-bucket ways register in every bucket their bbox touches -
    // deduplicate by id; the stretches would be identical anyway.
    final seen = <String>{};
    final out = <OverlayWay>[];
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final tileKey = _tileKey(x, y);
        if (!_hasBucket(tileKey)) continue;
        for (final way in _store.bucketByKey(tileKey)) {
          if (!seen.add(way.id)) continue;
          final stretches =
              unvisitedStretches(way.points, corridorsByWay[way.id] ?? const []);
          if (stretches.isNotEmpty) out.add((way.id, stretches));
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    _computedOverlayAtVersion = _corridorVersion;
    _lastOverlay = out;
    return out;
  }

  String _tileKey(int x, int y) => '${x}_$y';

  /// The x/y of the z12 tile containing [p] - the numbering
  /// [roadBucketKeyFor] buckets by, y growing southward.
  (int, int) _tileOf(LatLng p) {
    final parts = roadBucketKeyFor(p.latitude, p.longitude).split('_');
    return (int.parse(parts[0]), int.parse(parts[1]));
  }

  /// The z12 tile rectangle (x0, y0, x1, y1) covering the viewport from
  /// its [southWest] to its [northEast] corner, or null when it is
  /// wider or taller than [maxTiles] tiles (the caller's floor).
  (int, int, int, int)? _rectangleFor(LatLng southWest, LatLng northEast,
      {int? maxTiles}) {
    final (swX, swY) = _tileOf(southWest);
    final (neX, neY) = _tileOf(northEast);
    final x0 = math.min(swX, neX);
    final y0 = math.min(swY, neY);
    final x1 = math.max(swX, neX);
    final y1 = math.max(swY, neY);
    final floor = maxTiles ?? maxTilesPerAxis;
    if (x1 - x0 + 1 > floor || y1 - y0 + 1 > floor) {
      return null;
    }
    return (x0, y0, x1, y1);
  }

  /// Whether the store's directory has a payload for [key] - missing
  /// buckets (ocean, outside the extract) are skipped without a read.
  bool _hasBucket(String key) => _store.bucketPayloadBytes(key) > 0;

  /// Way-id-to-geometry-length for [key], from cache or by decoding
  /// the bucket's ways once. Ways register in every bucket their bbox
  /// touches, so a way's total is identical in each of its buckets.
  Map<String, double> _bucketTotals(String key) {
    final cached = _totals[key];
    if (cached != null) {
      _lru.remove(key);
      _lru.add(key);
      return cached;
    }
    final totals = <String, double>{};
    final distance = const Distance();
    for (final way in _store.bucketByKey(key)) {
      final pts = way.points;
      var total = 0.0;
      for (var i = 1; i < pts.length; i++) {
        total += distance.distance(pts[i - 1], pts[i]);
      }
      if (total > 0) totals[way.id] = total;
    }
    _totals[key] = totals;
    _lru.add(key);
    while (_lru.length > maxCachedBuckets) {
      _totals.remove(_lru.removeAt(0));
    }
    return totals;
  }

  /// The covered/uncovered road lengths over the viewport from its
  /// [southWest] to its [northEast] corner, from [corridorsByWay]
  /// (way id to corridor polylines, already merged across tracks by
  /// the caller). The pass yields between tile
  /// columns so a big first pass keeps the UI responsive; the result
  /// lands in one state update. Returns null below the zoom floor or
  /// when the view holds no roads.
  Future<CoverageReport?> coverage(
    LatLng southWest,
    LatLng northEast,
    Map<String, List<List<LatLng>>> corridorsByWay,
  ) async {
    final rectangle = _rectangleFor(southWest, northEast);
    if (rectangle == null) return null;
    final (x0, y0, x1, y1) = rectangle;
    final key = '$x0,$y0,$x1,$y1';
    if (key == _lastRectangle && _computedAtVersion == _corridorVersion) {
      return _lastReport;
    }
    _lastRectangle = key;

    // Way totals for the viewport, deduplicated across tiles: a way
    // registers in every bucket its bbox touches, so it must count
    // once, by its full length.
    final wayTotals = <String, double>{};
    var bucketCount = 0;
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final tileKey = _tileKey(x, y);
        if (!_hasBucket(tileKey)) continue;
        final totals = _bucketTotals(tileKey);
        if (totals.isEmpty) continue;
        bucketCount++;
        totals.forEach((id, total) {
          wayTotals.putIfAbsent(id, () => total);
        });
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (wayTotals.isEmpty) {
      _computedAtVersion = _corridorVersion;
      _lastReport = null;
      return null;
    }

    var totalMeters = 0.0;
    var coveredMeters = 0.0;
    final distance = const Distance();
    for (final entry in wayTotals.entries) {
      final total = entry.value;
      totalMeters += total;
      final corridors = corridorsByWay[entry.key];
      if (corridors == null) continue;
      var covered = 0.0;
      for (final corridor in corridors) {
        for (var i = 1; i < corridor.length; i++) {
          covered += distance.distance(corridor[i - 1], corridor[i]);
        }
      }
      coveredMeters += covered.clamp(0.0, total);
    }
    _computedAtVersion = _corridorVersion;
    final report = CoverageReport(
      totalMeters: totalMeters,
      matchedMeters: coveredMeters,
      wayCount: wayTotals.length,
      bucketCount: bucketCount,
    );
    _lastReport = report;
    return report;
  }
}
