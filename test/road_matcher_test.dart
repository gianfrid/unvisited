import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/road/road_matcher.dart';
import 'package:unvisited/road/road_store.dart';

import 'helpers.dart';

void main() {
  late RoadStore store;
  late GeometricRoadMatcher matcher;

  setUp(() {
    store = RoadStore.parse(fixture('test_roads.unvisited-roads'));
    matcher = GeometricRoadMatcher(store);
  });

  /// Points every ~30 m along a straight lat/lon line, inclusive.
  List<LatLng> line(LatLng from, LatLng to) {
    final n = (const Distance().distance(from, to) / 30).ceil();
    return [
      for (var i = 0; i <= n; i++)
        LatLng(
          from.latitude + (to.latitude - from.latitude) * i / n,
          from.longitude + (to.longitude - from.longitude) * i / n,
        ),
    ];
  }

  test('walking a street unlocks that street completely', () {
    // Main Street runs west→east at lat 52.5200.
    final result = matcher.match(
        line(const LatLng(52.5200, 13.4050), const LatLng(52.5200, 13.4100)));
    expect(result.matchedMeters.keys, contains('1001'));
    expect(result.ratioFor('1001'), greaterThan(0.99));
  });

  test('corridors carry the walked geometry, cut out of the way', () {
    final result = matcher.match(
        line(const LatLng(52.5200, 13.4050), const LatLng(52.5200, 13.4100)));
    final corridors = result.corridors['1001']!;
    // The corridor is the walked stretch of the way, end to end.
    final pts = corridors.expand((c) => c).toList();
    expect(pts.first.latitude, closeTo(52.5200, 1e-4));
    expect(pts.first.longitude, closeTo(13.4050, 1e-3));
    expect(pts.last.longitude, closeTo(13.4100, 1e-3));
  });

  test('two disjoint visits to one way yield two corridors', () {
    // Touch Cross Avenue far north, then far south: two separate lit
    // stretches, not one corridor spanning the unvisited gap between.
    final result = matcher.match(const [
      LatLng(52.5218, 13.4075),
      LatLng(52.5182, 13.4075),
    ]);
    expect(result.corridors['1002']!.length, 2);
    // The gap between the two corridors is unlit (no points spanning it).
    for (final corridor in result.corridors['1002']!) {
      for (final p in corridor) {
        expect(
            (p.latitude - 52.5200).abs(), greaterThan(0.001),
            reason: 'the unvisited middle must not be in any corridor');
      }
    }
  });

  test('crossing a street unlocks part of it, not all', () {
    // The Main Street walk crosses Cross Avenue (lon 13.4075) once.
    final result = matcher.match(
        line(const LatLng(52.5200, 13.4050), const LatLng(52.5200, 13.4100)));
    final ratio = result.ratioFor('1002');
    expect(ratio, greaterThan(0.0),
        reason: 'the intersection area must unlock');
    expect(ratio, lessThan(0.2),
        reason: 'only the corridor around the crossing unlocks');
  });

  test('a parallel street 44 m away stays locked', () {
    // Parallel Lane sits 0.0004° (~44 m) north of Main Street — outside the
    // 15 m unlock radius. Walking Main Street must not unlock it.
    final result = matcher.match(
        line(const LatLng(52.5200, 13.4050), const LatLng(52.5200, 13.4100)));
    expect(result.matchedMeters.containsKey('1003'), isFalse);
  });

  test('walking the parallel street unlocks it instead', () {
    final result = matcher.match(
        line(const LatLng(52.5204, 13.4050), const LatLng(52.5204, 13.4100)));
    expect(result.matchedMeters.keys, contains('1003'));
    expect(result.ratioFor('1003'), greaterThan(0.99));
    expect(result.matchedMeters.containsKey('1001'), isFalse);
  });

  test('standing at an intersection unlocks all four arms a little', () {
    // One point at the Main Street × Cross Avenue junction.
    final result = matcher.match(const [LatLng(52.5200, 13.4075)]);
    expect(result.ratioFor('1001'), greaterThan(0));
    expect(result.ratioFor('1002'), greaterThan(0));
  });

  test('matching parses only the buckets the track touches', () {
    // The fixture is a single bucket, so this asserts the lazy contract on
    // the store the matcher uses: a match reads buckets, never the file.
    final store = RoadStore.parse(fixture('test_roads.unvisited-roads'));
    final matcher = GeometricRoadMatcher(store);
    matcher.match(const [LatLng(52.5200, 13.4075)]);
    expect(store.parsedBucketCount, 1,
        reason: 'one bucket, parsed once, then cached');
    matcher.match(const [LatLng(52.5200, 13.4075)]);
    expect(store.parsedBucketCount, 1, reason: 'repeat match hits the cache');
  });

  test('no unlock centers → no unlocked ways', () {
    final result = matcher.match(const []);
    expect(result.matchedMeters, isEmpty);
    expect(result.ratioFor('1001'), 0);
  });

  test('a point far from any road unlocks nothing', () {
    // ~10 km east of the fixture streets: other buckets entirely.
    final result = matcher.match(const [LatLng(52.5200, 13.5200)]);
    expect(result.matchedMeters, isEmpty);
  });

  test('a track outside the region entirely matches nothing', () {
    // ~880 km away (Paris): the region file holds no ways there, so the
    // matcher must unlock nothing — corridor marks can never "leak" from a
    // region into a zone it does not cover.
    final result = matcher.match(const [
      LatLng(48.8566, 2.3522),
      LatLng(48.8570, 2.3530),
      LatLng(48.8580, 2.3540),
    ]);
    expect(result.matchedMeters, isEmpty);
    expect(result.corridors, isEmpty);
    // Only the index's reference-latitude bucket (parsed once when the
    // index is built, for the longitude cell width) was touched — none of
    // the far-away query's own buckets exist in the file.
    expect(store.parsedBucketCount, 1);
  });
}
