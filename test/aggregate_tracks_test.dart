import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/aggregate/aggregate_tracks.dart';

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
  });
}
