import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../geo.dart' show haversineMeters;

/// One catalog track as the aggregate index sees it. Pure Dart — no
/// Flutter imports — so clustering stays unit-testable like the parsers.
class AggregateInput {
  const AggregateInput({
    required this.id,
    required this.points,
    this.startTimeUtc,
  });

  final String id; // content hash (FNV-1a 64-bit hex)
  final List<LatLng> points;
  final DateTime? startTimeUtc;
}

/// A cluster of tracks whose points come within the threshold of each
/// other (transitively — chains join through intermediate tracks).
class AggregateTrack {
  AggregateTrack(this.members);

  final List<AggregateInput> members;

  List<String> get trackIds => [for (final m in members) m.id];

  List<LatLng> get points => [
    for (final m in members) ...m.points,
  ];

  /// The member with the earliest start time (tracks without a start time
  /// sort last; ties break by id so the anchor is deterministic). This is
  /// the stable identity for persisted per-aggregate state such as the
  /// color override: adding or removing other members never changes it.
  String get anchorId {
    var best = members.first;
    for (final m in members.skip(1)) {
      final a = best.startTimeUtc;
      final b = m.startTimeUtc;
      if (b == null) continue;
      if (a == null || b.isBefore(a) || (b == a && m.id.compareTo(best.id) < 0)) {
        best = m;
      }
    }
    return best.id;
  }
}

/// Clusters tracks into aggregates. The interface mirrors the parsers': a
/// pure-Dart implementation behind a small seam, so a different clustering
/// strategy (or a future Rust core) can slot in unchanged.
abstract class AggregateIndex {
  List<AggregateTrack> build(
    List<AggregateInput> tracks, {
    double thresholdMeters,
  });
}

/// Union-find over tracks, joined when any point pair across two tracks is
/// within [thresholdMeters]. Points are bucketed into a lat/lon grid with
/// cell edge = threshold (longitude cells scaled by cos(latitude)), so any
/// two points within the threshold sit in the same or adjacent cells. The
/// scan visits each unordered pair of neighboring cells once and skips a
/// cell pair entirely once every track in one cell is already united with
/// every track in the other — a single close point pair joins two tracks,
/// so further point pairs cannot change the partition. Inside a scanned
/// pair, a degree-space reject (|dLat|, |dLon| bounds) filters before the
/// haversine, keeping near-miss pairs cheap. O(n) in the point count per
/// area, not O(n^2) pairwise.
class UnionFindAggregateIndex implements AggregateIndex {
  const UnionFindAggregateIndex({this.defaultThresholdMeters = 100});

  final double defaultThresholdMeters;

  @override
  List<AggregateTrack> build(
    List<AggregateInput> tracks, {
    double? thresholdMeters,
  }) {
    final threshold = thresholdMeters ?? defaultThresholdMeters;
    final parent = List<int>.generate(tracks.length, (i) => i);
    int find(int i) {
      while (parent[i] != i) {
        parent[i] = parent[parent[i]];
        i = parent[i];
      }
      return i;
    }

    // cell key -> cell record (coords, points, track set)
    const metersPerDegLat = 111320.0;
    final latCellDeg = threshold / metersPerDegLat;
    final cells = <String, ({int cx, int cy, List<(int, LatLng)> points, Set<int> tracks})>{};
    for (var t = 0; t < tracks.length; t++) {
      for (final p in tracks[t].points) {
        final cx = (p.latitude / latCellDeg).floor();
        final cy = (p.longitude /
                (threshold / (metersPerDegLat * _cosLat(p.latitude))))
            .floor();
        final cell = cells.putIfAbsent(
          '$cx,$cy',
          () => (cx: cx, cy: cy, points: [], tracks: <int>{}),
        );
        cell.points.add((t, p));
        cell.tracks.add(t);
      }
    }
    for (final cell in cells.values) {
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final sameCell = dx == 0 && dy == 0;
          // Visit each unordered pair of neighboring cells once.
          if (!sameCell && (dx < 0 || (dx == 0 && dy < 0))) continue;
          final other =
              sameCell ? cell : cells['${cell.cx + dx},${cell.cy + dy}'];
          if (other == null) continue;
          // Cell-pair early exit: when all cross-cell track pairs are
          // already united, no point pair below can change the partition.
          var allUnited = true;
          for (final t in cell.tracks) {
            for (final u in other.tracks) {
              if (t != u && find(t) != find(u)) {
                allUnited = false;
                break;
              }
            }
            if (!allUnited) break;
          }
          if (allUnited) continue;
          final a = cell.points;
          final b = other.points;
          for (var i = 0; i < a.length; i++) {
            final (t, p) = a[i];
            final lonBound = latCellDeg / _cosLat(p.latitude);
            for (var j = sameCell ? i + 1 : 0; j < b.length; j++) {
              final (u, q) = b[j];
              if (t == u) continue;
              final ra = find(t), rb = find(u);
              // Already in the same cluster: the union would be a no-op.
              if (ra == rb) continue;
              // Degree-space reject before the haversine: points farther
              // than the threshold in either axis cannot be within it.
              if ((q.latitude - p.latitude).abs() > latCellDeg) continue;
              if ((q.longitude - p.longitude).abs() > lonBound) continue;
              if (haversineMeters(p.latitude, p.longitude, q.latitude,
                      q.longitude) <=
                  threshold) {
                parent[ra] = rb;
              }
            }
          }
        }
      }
    }
    final groups = <int, List<AggregateInput>>{};
    for (var t = 0; t < tracks.length; t++) {
      groups.putIfAbsent(find(t), () => []).add(tracks[t]);
    }
    return [for (final g in groups.values) AggregateTrack(g)];
  }

  static double _cosLat(double lat) {
    // Longitude cells shrink with the cosine of the latitude; floor near
    // the poles so the grid stays finite.
    return math.max(math.cos(lat * math.pi / 180), 0.01);
  }
}
