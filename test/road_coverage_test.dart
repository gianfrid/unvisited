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

  group('unvisited overlay', () {
    test('no corridors leaves every way fully dark', () async {
      final overlay =
          await coverage.unvisitedIn(blockView().$1, blockView().$2, {});
      expect(overlay.map((w) => w.$1).toSet(), {'1001', '1002', '1003', '1004'});
      for (final way in overlay) {
        expect(way.$2, hasLength(1));
      }
    });

    test('a fully walked way drops out of the overlay', () async {
      final overlay = await coverage.unvisitedIn(
        blockView().$1,
        blockView().$2,
        {
          // Main Street walked end to end.
          '1001': [
            List.of(store
                .bucketAt(52.5200, 13.4075)
                .singleWhere((w) => w.id == '1001')
                .points),
          ],
        },
      );
      expect(overlay.map((w) => w.$1), isNot(contains('1001')));
      expect(overlay.map((w) => w.$1), containsAll(['1002', '1003', '1004']));
    });

    test('a mid-way corridor darkens only the ends', () async {
      final main = store
          .bucketAt(52.5200, 13.4075)
          .singleWhere((w) => w.id == '1001');
      final total = const Distance()
          .distance(main.points.first, main.points.last);
      final overlay = await coverage.unvisitedIn(
        blockView().$1,
        blockView().$2,
        {
          '1001': [
            [main.points.first, const LatLng(52.5200, 13.4075)],
          ],
        },
      );
      final entry = overlay.singleWhere((w) => w.$1 == '1001');
      expect(entry.$2.length, 1);
      final dark = entry.$2.fold<double>(
          0, (sum, s) => sum + const Distance().distance(s.first, s.last));
      expect(dark, closeTo(total / 2, total * 0.02));
    });

    test('the overlay floor is tighter than the chip floor', () async {
      // A viewport within the chip's 6x6 floor but wider than the
      // overlay's 3x3: the chip answers, the overlay abstains.
      final wide = await coverage
          .coverage(const LatLng(52.4, 13.2), const LatLng(52.65, 13.65), {});
      expect(wide, isNotNull);
      final overlay = await coverage.unvisitedIn(
          const LatLng(52.4, 13.2), const LatLng(52.65, 13.65), {});
      expect(overlay, isEmpty);
    });

    test('memoized: an unchanged viewport decodes nothing new', () async {
      await coverage.unvisitedIn(blockView().$1, blockView().$2, {});
      final parsed = store.parsedBucketCount;
      final first =
          await coverage.unvisitedIn(blockView().$1, blockView().$2, {});
      final second =
          await coverage.unvisitedIn(blockView().$1, blockView().$2, {});
      expect(identical(first, second), isTrue);
      expect(store.parsedBucketCount, parsed);
    });
  });

  group('viewport clipping', () {
    test('ways in the tile but outside the screen do not count', () async {
      // A tight view at the tile's south-west corner: Cross Avenue
      // (lon 13.4075) misses it by longitude, Main Street/Parallel/
      // Service (lat ~52.5200) miss it by latitude - nothing on screen,
      // so the answer is null, not the whole tile's share.
      final report = await coverage.coverage(
          const LatLng(52.5181, 13.4051), const LatLng(52.5183, 13.4055), {});
      expect(report, isNull);
    });

    test('a partially visible way still counts fully', () async {
      // The screen cuts Main Street's west end: its bbox straddles the
      // edge, so the way is in the sums (bbox conservatism, same rule
      // as bucket registration).
      final report = await coverage.coverage(
          const LatLng(52.5199, 13.4070), const LatLng(52.5201, 13.4090), {});
      expect(report, isNotNull);
      // Main Street (lat 52.5200), Service Road (lat 52.5200719) and
      // Cross Avenue (lat 52.5180..52.5220, lon 13.4075) all reach this
      // rectangle; only Parallel Lane (lat 52.5204) is off-screen.
      expect(report!.wayCount, 3);
    });

    test('the overlay draws only the bbox-intersecting ways', () async {
      final overlay = await coverage.unvisitedIn(
          const LatLng(52.5199, 13.4070), const LatLng(52.5201, 13.4090), {});
      expect(overlay.map((w) => w.$1).toSet(), {'1001', '1002', '1004'});
    });

    test('the wide view still sees every street', () async {
      final report = await coverage.coverage(blockView().$1, blockView().$2, {});
      expect(report!.wayCount, 4);
      final overlay =
          await coverage.unvisitedIn(blockView().$1, blockView().$2, {});
      expect(overlay.length, 4);
    });
  });
}
