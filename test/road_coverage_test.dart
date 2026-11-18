import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/road/road_store.dart';
import 'package:unvisited/road/road_coverage.dart';

import 'helpers.dart';

/// The synthetic fixture (see test/fixtures/test_roads_source.json):
/// four straight streets around (52.52, 13.4075) —
///   1001 Main Street,   lat 52.5200, lon 13.4050..13.4100
///   1002 Cross Avenue,   lon 13.4075, lat 52.5180..52.5220
///   1003 Parallel Lane,  lat 52.5204, lon 13.4050..13.4100
///   1004 Service Road,   lat 52.5200719, lon 13.4050..13.4100
void main() {
  late RoadStore store;
  late ViewportCoverage coverage;

  setUp(() {
    store = RoadStore.parse(fixture('test_roads.unvisited-roads'));
    coverage = ViewportCoverage(store, maxTilesPerAxis: 6);
  });

  /// Viewport covering the whole fixture block, well inside the 6x6
  /// floor.
  (LatLng, LatLng) blockView() => (
        const LatLng(52.515, 13.400),
        const LatLng(52.525, 13.415)
      );

  test('sums every viewport way into the denominator', () async {
    final report = await coverage.coverage(blockView().$1, blockView().$2, {});
    // All four fixture streets sit inside one bucket, so all of them
    // count, once each (multi-bucket ways are deduplicated).
    expect(report, isNotNull);
    expect(report!.wayCount, 4);
    expect(report.totalMeters, greaterThan(1400));
    // No unlock state: everything is unvisited.
    expect(report.unvisitedRatio, closeTo(1.0, 1e-9));
    expect(report.matchedMeters, 0);
  });

  test('a corridor covering half a way halves its share', () async {
    // An hand-cut corridor from Main Street's west end to its midpoint;
    // corridor polylines are cut at meter offsets along the way's own
    // geometry, so the half-length corridor is exactly half the way.
    final corridor = [
      const LatLng(52.5200, 13.4050),
      const LatLng(52.5200, 13.4075),
    ];
    final report = await coverage.coverage(
      blockView().$1,
      blockView().$2,
      {'1001': [corridor]},
    );
    expect(report, isNotNull);
    final way = store.bucketAt(52.5200, 13.4075)
        .singleWhere((w) => w.id == '1001');
    final wayMeters = const Distance()
        .distance(way.points.first, way.points.last);
    expect(report!.matchedMeters, closeTo(wayMeters / 2, wayMeters * 0.02));
    expect(
      report.unvisitedRatio,
      closeTo(1 - (wayMeters / 2) / report.totalMeters, 1e-3),
    );
  });

  test('overlapping corridors from two tracks cap at the way total',
      () async {
    // Both tracks walk the whole street: their corridors coincide, but
    // the sum must cap at the way's own length, never double it.
    final corridor = [
      const LatLng(52.5200, 13.4050),
      const LatLng(52.5200, 13.4100),
    ];
    final report = await coverage.coverage(
      blockView().$1,
      blockView().$2,
      {'1001': [corridor, List.of(corridor)]},
    );
    expect(report, isNotNull);
    final way = store.bucketAt(52.5200, 13.4075)
        .singleWhere((w) => w.id == '1001');
    final wayMeters = const Distance()
        .distance(way.points.first, way.points.last);
    expect(report!.matchedMeters, closeTo(wayMeters, wayMeters * 0.01));
  });

  test('corridors of ways outside the store are ignored', () async {
    // An unlock corridor from some other region, whose way ids do not
    // intersect the active store's buckets: contributes nothing.
    final corridor = [
      const LatLng(39.9, 8.9),
      const LatLng(39.9, 8.91),
    ];
    final report = await coverage.coverage(
      blockView().$1,
      blockView().$2,
      {'99999': [corridor]},
    );
    expect(report, isNotNull);
    expect(report!.matchedMeters, 0);
  });

  test('a viewport with no road buckets reports nothing', () async {
    // Far from the fixture's tile: no denominator, so the answer is
    // null (there is no share of an empty network), not 100%.
    final report = await coverage
        .coverage(const LatLng(45.0, 5.0), const LatLng(45.05, 5.05), {});
    expect(report, isNull);
  });

  test('viewports beyond the tile floor report nothing', () async {
    // A continent-scale rectangle is wider than six z12 tiles per
    // axis: below the floor the answer is deferred, not guessed.
    final report = await coverage
        .coverage(const LatLng(52.0, 13.0), const LatLng(53.0, 15.0), {});
    expect(report, isNull);
  });

  test('memoized: an unchanged viewport decodes nothing new', () async {
    await coverage.coverage(blockView().$1, blockView().$2, {});
    final parsed = store.parsedBucketCount;
    final first = await coverage.coverage(blockView().$1, blockView().$2, {});
    final second = await coverage.coverage(blockView().$1, blockView().$2, {});
    expect(identical(first, second), isTrue);
    expect(store.parsedBucketCount, parsed);
  });

  test('invalidate drops the memo but not the bucket caches', () async {
    await coverage.coverage(blockView().$1, blockView().$2, {});
    final parsed = store.parsedBucketCount;
    coverage.invalidate();
    final report =
        await coverage.coverage(blockView().$1, blockView().$2, {});
    expect(report, isNotNull);
    // The bucket totals (geometry lengths) are immutable per store, so
    // the recompute reuses the decoded buckets and only re-reads the
    // (now empty) corridor input.
    expect(store.parsedBucketCount, parsed);
  });
}
