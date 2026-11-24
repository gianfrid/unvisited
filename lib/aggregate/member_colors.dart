import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../geo.dart' show haversineMeters;
import 'aggregate_tracks.dart' show AggregateInput;

/// Assigns each member track of a selected aggregate its own tint key, so
/// the member-picking mode can draw every track on the map in a distinct
/// color. Two tracks count as *near* when any pair of their points comes
/// within [nearMeters]; near tracks never share a color while the palette
/// lasts (repetitions are allowed — and unavoidable past the palette size
/// — only for tracks that do not overlap). Pure Dart — no Flutter imports
/// — so the assignment stays unit-testable like the clustering.
///
/// Adjacency is found with the same grid-bucketed neighbor scan the
/// union-find in `aggregate_tracks.dart` uses (cell edge = nearMeters,
/// longitude cells scaled by cos(latitude), each unordered cell pair
/// visited once, degree-space reject before the haversine), so the scan is
/// O(points) per area, not O(n²) pairwise. The coloring itself is greedy:
/// members ordered by descending degree (ties broken by id, so the result
/// is deterministic) take the first palette key no neighbor already has.
Map<String, String> assignMemberTintKeys(
  List<AggregateInput> members, {
  double nearMeters = 30,
  required List<String> palette,
}) {
  if (palette.isEmpty) {
    throw ArgumentError.value(palette, 'palette', 'must not be empty');
  }
  final n = members.length;
  if (n == 0) return const {};
  final adj = List<Set<int>>.generate(n, (_) => <int>{});

  const metersPerDegLat = 111320.0;
  final latCellDeg = nearMeters / metersPerDegLat;
  final cells = <String, ({int cx, int cy, List<(int, LatLng)> points})>{};
  for (var t = 0; t < n; t++) {
    for (final p in members[t].points) {
      final cx = (p.latitude / latCellDeg).floor();
      final cy = (p.longitude /
              (nearMeters / (metersPerDegLat * _cosLat(p.latitude))))
          .floor();
      cells
          .putIfAbsent(
              '$cx,$cy', () => (cx: cx, cy: cy, points: <(int, LatLng)>[]))
          .points
          .add((t, p));
    }
  }
  for (final cell in cells.values) {
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        final sameCell = dx == 0 && dy == 0;
        // Visit each unordered pair of neighboring cells once.
        if (!sameCell && (dx < 0 || (dx == 0 && dy < 0))) continue;
        final other = sameCell ? cell : cells['${cell.cx + dx},${cell.cy + dy}'];
        if (other == null) continue;
        for (var i = 0; i < cell.points.length; i++) {
          final (t, p) = cell.points[i];
          final lonBound = latCellDeg / _cosLat(p.latitude);
          for (var j = sameCell ? i + 1 : 0; j < other.points.length; j++) {
            final (u, q) = other.points[j];
            if (t == u) continue;
            if ((q.latitude - p.latitude).abs() > latCellDeg) continue;
            if ((q.longitude - p.longitude).abs() > lonBound) continue;
            if (haversineMeters(p.latitude, p.longitude, q.latitude,
                    q.longitude) <=
                nearMeters) {
              adj[t].add(u);
              adj[u].add(t);
            }
          }
        }
      }
    }
  }

  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) {
      final byDegree = adj[b].length.compareTo(adj[a].length);
      if (byDegree != 0) return byDegree;
      return members[a].id.compareTo(members[b].id);
    });
  final assigned = List<String?>.filled(n, null);
  final result = <String, String>{};
  for (final i in order) {
    final used = {
      for (final j in adj[i])
        if (assigned[j] != null) assigned[j]!,
    };
    String key = palette.first;
    for (final candidate in palette) {
      if (!used.contains(candidate)) {
        key = candidate;
        break;
      }
    }
    assigned[i] = key;
    result[members[i].id] = key;
  }
  return result;
}

double _cosLat(double lat) {
  // Longitude cells shrink with the cosine of the latitude; floor near
  // the poles so the grid stays finite.
  return math.max(math.cos(lat * math.pi / 180), 0.01);
}
