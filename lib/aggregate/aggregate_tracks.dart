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
/// cell edge = threshold (longitude cells scaled by cos(latitude)), so
/// the neighbor query touches only the 3x3 surrounding cells — O(n) in the
/// point count per area, not O(n^2) pairwise.
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

    // cell key -> list of (track index, point)
    final grid = <String, List<(int, LatLng)>>{};
    const metersPerDegLat = 111320.0;
    for (var t = 0; t < tracks.length; t++) {
      for (final p in tracks[t].points) {
        final latCell = p.latitude / (threshold / metersPerDegLat);
        final lonCell = p.longitude /
            (threshold / (metersPerDegLat * _cosLat(p.latitude)));
        grid
            .putIfAbsent('${latCell.floor()},${lonCell.floor()}', () => [])
            .add((t, p));
      }
    }
    for (var t = 0; t < tracks.length; t++) {
      for (final p in tracks[t].points) {
        final latCell = p.latitude / (threshold / metersPerDegLat);
        final lonCell = p.longitude /
            (threshold / (metersPerDegLat * _cosLat(p.latitude)));
        for (var dx = -1; dx <= 1; dx++) {
          for (var dy = -1; dy <= 1; dy++) {
            final cell = grid['${latCell.floor() + dx},${lonCell.floor() + dy}'];
            if (cell == null) continue;
            for (final (other, q) in cell) {
              if (other == t) continue;
              final ra = find(t), rb = find(other);
              // Already in the same cluster: the union would be a no-op,
              // so skip the haversine — the dominant cost on chained
              // catalogs, where most pairs are already united.
              if (ra == rb) continue;
              if (haversineMeters(p.latitude, p.longitude, q.latitude, q.longitude) <=
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
