import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/road/road_store.dart';

import '../tool/road_bench.dart';
import 'helpers.dart';

void main() {
  group('road bench', () {
    late RoadStore store;
    late Map<String, Object> result;

    setUp(() {
      store = RoadStore.parse(fixture('test_roads.unvisited-roads'));
      // The walk is aimed at Main Street (lat 52.5200 — the line the fixture's
      // roads run along) rather than the densest bucket's center, so the
      // match numbers exercise real geometry.
      result = benchRoadStore(store,
          walkPoints: 400,
          warmRuns: 3,
          walkOrigin: const LatLng(52.5200, 13.4075));
    });

    test('reports the store structure', () {
      expect(result['buckets'], greaterThan(0));
      expect(result['ways'], greaterThan(0));
      expect(result['payloadBytes'], greaterThan(0));
      expect(result['directoryBytes'], greaterThan(0));
      expect(result['densestKey'], isNotEmpty);
      expect(result['densestWays'], greaterThan(0));
    });

    test('reports sane timing numbers', () {
      expect(result['scanMs'] as double, greaterThanOrEqualTo(0));
      expect(result['avgBucketMs'] as double, greaterThanOrEqualTo(0));
      expect(result['maxBucketMs'] as double,
          greaterThanOrEqualTo(result['avgBucketMs'] as double));
      expect(result['coldMs'] as double, greaterThanOrEqualTo(0));
      final warms = result['warmMs'] as List<double>;
      expect(warms, hasLength(3));
      for (final ms in warms) {
        expect(ms, greaterThanOrEqualTo(0));
      }
    });

    test('the aimed walk matches the fixture streets', () {
      expect(result['walkPoints'], greaterThan(0));
      expect(result['matchedWays'], greaterThan(0));
      expect(result['matchedMeters'] as double, greaterThan(0));
      expect(result['corridors'], greaterThan(0));
    });

    test('the report renders every measured field', () {
      final report = benchReport(result);
      expect(report, contains('road file:'));
      expect(report, contains('open (parse + index): n/a (in-memory store)'));
      expect(report, contains('payload scan:'));
      expect(report, contains('match cold:'));
      expect(report, contains('match warm:'));
    });
  });
}
