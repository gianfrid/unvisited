import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/aggregate/aggregate_tracks.dart';
import 'package:unvisited/geo.dart' show haversineMeters;

/// Synthetic fixtures for the aggregate clustering: chains, singletons and
/// threshold edge cases, all on a small lat/lon grid near 45N (about
/// 78.6 m per 0.001 deg of longitude there, 111.2 m per 0.001 deg of
/// latitude).

void main() {
  const base = LatLng(45.0, 9.0);

  /// ~dMeters east of [base] along the parallel.
  LatLng eastOf(LatLng p, double dMeters) =>
      LatLng(p.latitude, p.longitude + dMeters / 78600);

  AggregateInput track(
    String id,
    List<LatLng> points, {
    DateTime? start,
  }) =>
      AggregateInput(id: id, points: points, startTimeUtc: start);

  final t0 = DateTime.utc(2026, 1, 1);

  group('UnionFindAggregateIndex', () {
    test('empty input yields no aggregates', () {
      const index = UnionFindAggregateIndex();
      expect(index.build(const []), isEmpty);
    });

    test('a singleton track is its own aggregate', () {
      const index = UnionFindAggregateIndex();
      final result = index.build([
        track('a', [base, eastOf(base, 10)]),
      ]);
      expect(result, hasLength(1));
      expect(result.single.trackIds, ['a']);
      expect(result.single.anchorId, 'a');
    });

    test('two tracks within the threshold join', () {
      const index = UnionFindAggregateIndex();
      final result = index.build([
        track('a', [base]),
        track('b', [eastOf(base, 99)]),
      ]);
      expect(result, hasLength(1));
      expect(result.single.trackIds, unorderedEquals(['a', 'b']));
    });

    test('two tracks beyond the threshold stay separate', () {
      const index = UnionFindAggregateIndex();
      final result = index.build([
        track('a', [base]),
        track('b', [eastOf(base, 101)]),
      ]);
      expect(result, hasLength(2));
    });

    test('chains join transitively through an intermediate track', () {
      const index = UnionFindAggregateIndex();
      // a-b within 100 m, b-c within 100 m, a-c beyond 100 m.
      final result = index.build([
        track('a', [base]),
        track('b', [eastOf(base, 90)]),
        track('c', [eastOf(base, 170)]),
      ]);
      expect(result, hasLength(1));
      expect(result.single.trackIds, unorderedEquals(['a', 'b', 'c']));
      expect(result.single.points, hasLength(3));
    });

    test('the anchor is the earliest-starting member', () {
      const index = UnionFindAggregateIndex();
      final result = index.build([
        track('newer', [base], start: t0.add(const Duration(days: 2))),
        track('oldest', [eastOf(base, 50)], start: t0),
        track('middle', [eastOf(base, 90)], start: t0.add(const Duration(days: 1))),
      ]);
      expect(result.single.anchorId, 'oldest');
    });

    test('anchor is deterministic for equal start times and survives membership changes', () {
      const index = UnionFindAggregateIndex();
      final baseAgg = index.build([
        track('b', [base], start: t0),
        track('a', [eastOf(base, 50)], start: t0),
      ]);
      // Same start times: lowest id wins, and adding another member does
      // not change the anchor.
      expect(baseAgg.single.anchorId, 'a');
      final grown = index.build([
        track('b', [base], start: t0),
        track('a', [eastOf(base, 50)], start: t0),
        track('c', [eastOf(base, 90)], start: t0.add(const Duration(days: 5))),
      ]);
      expect(grown.single.anchorId, 'a');
      // Removing a non-anchor member keeps the anchor too.
      final shrunk = index.build([
        track('a', [eastOf(base, 50)], start: t0),
        track('c', [eastOf(base, 90)], start: t0.add(const Duration(days: 5))),
      ]);
      expect(shrunk.single.anchorId, 'a');
    });

    test('a custom threshold overrides the 100 m default', () {
      const index = UnionFindAggregateIndex();
      final tight = index.build(
        [track('a', [base]), track('b', [eastOf(base, 50)])],
        thresholdMeters: 30,
      );
      expect(tight, hasLength(2));
      final loose = index.build(
        [track('a', [base]), track('b', [eastOf(base, 150)])],
        thresholdMeters: 200,
      );
      expect(loose, hasLength(1));
    });

    test('matches a brute-force reference on a random catalog', () {
      // The grid/cell-pair scan is an optimization of the plain "any point
      // pair across two tracks within the threshold unions them" rule —
      // on a seeded random catalog (dense clusters, chains, near-miss
      // parallel lines) the partitions must agree exactly.
      final rng = math.Random(20261116);
      const threshold = 100.0;
      final inputs = <AggregateInput>[];
      // 24 random-walk tracks around 5 centers: dense clusters and chains.
      for (var t = 0; t < 24; t++) {
        var lat = 45.0 + (t % 5) * 0.004 + rng.nextDouble() * 0.002;
        var lon = 9.0 + rng.nextDouble() * 0.004;
        final pts = <LatLng>[];
        for (var i = 0; i < 100; i++) {
          pts.add(LatLng(lat, lon));
          lat += (rng.nextDouble() - 0.5) * 0.0012;
          lon += (rng.nextDouble() - 0.5) * 0.0016;
        }
        inputs.add(track('walk$t', pts));
      }
      // 8 parallel lines ~150 m apart: near-misses that must stay separate.
      for (var t = 0; t < 8; t++) {
        final lat0 = 45.05 + t * 150 / 111320.0;
        inputs.add(track(
          'line$t',
          [for (var i = 0; i < 100; i++) LatLng(lat0, 9.1 + i * 5 / 78600.0)],
        ));
      }

      Set<Set<String>> partitionOf(List<AggregateTrack> aggregates) => {
        for (final a in aggregates) a.trackIds.toSet(),
      };

      // Brute-force reference: union-find over every cross-track point pair.
      final parent = List<int>.generate(inputs.length, (i) => i);
      int find(int i) {
        while (parent[i] != i) {
          parent[i] = parent[parent[i]];
          i = parent[i];
        }
        return i;
      }

      for (var a = 0; a < inputs.length; a++) {
        for (var b = a + 1; b < inputs.length; b++) {
          var joined = false;
          for (final p in inputs[a].points) {
            for (final q in inputs[b].points) {
              if (haversineMeters(
                      p.latitude, p.longitude, q.latitude, q.longitude) <=
                  threshold) {
                parent[find(a)] = find(b);
                joined = true;
                break;
              }
            }
            if (joined) break;
          }
        }
      }
      final reference = <int, Set<String>>{};
      for (var t = 0; t < inputs.length; t++) {
        reference.putIfAbsent(find(t), () => {}).add(inputs[t].id);
      }

      const index = UnionFindAggregateIndex();
      final result = index.build(inputs, thresholdMeters: threshold);
      expect(partitionOf(result), reference.values.map((s) => s.toSet()).toSet());
    });
  });
}
