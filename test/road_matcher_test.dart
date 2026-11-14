import 'dart:math' as math;

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

  test('crossing a street mid-block unlocks part of it', () {
    // A lat line at 52.5210 (111 m north of Main Street, mid-block on Cross
    // Avenue) crosses Cross Avenue at lon 13.4075. With no rival way in
    // radius there, attribution switches to it and lights the slice walked.
    final result = matcher.match(
        line(const LatLng(52.5210, 13.4050), const LatLng(52.5210, 13.4100)));
    final ratio = result.ratioFor('1002');
    expect(ratio, greaterThan(0.0),
        reason: 'the crossing corridor must unlock');
    expect(ratio, lessThan(0.2),
        reason: 'only the corridor around the crossing unlocks');
    expect(result.matchedMeters.containsKey('1001'), isFalse);
  });

  test('walking a street through a junction lights it, not the cross street', () {
    // Straight through the Main Street × Cross Avenue junction on Cross
    // Avenue: Main Street is never more than a wobble away from the active
    // way at the junction itself, so attribution stays on the ridden street
    // (the fog circles still light the junction area).
    final result = matcher.match(
        line(const LatLng(52.5218, 13.4075), const LatLng(52.5182, 13.4075)));
    // 0.95, not 1.0: the single center sitting exactly on the junction
    // (distance 0 to both centerlines) can go to either way, leaving a
    // ~15 m hole on the ridden street — invisible under the fog circles.
    expect(result.ratioFor('1002'), greaterThan(0.95));
    expect(result.matchedMeters.containsKey('1001'), isFalse);
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

  test('wobbling between Main Street and the service road stays on Main', () {
    // Service Road runs 8 m north of Main Street (within the 15 m radius of
    // every point). Riding Main Street with ±3 m GPS jitter must attribute
    // every center to Main Street — sub-margin rival distance may not split
    // the matched length onto the un-ridden way.
    const jitter = 3.0 / 111320; // 3 m in degrees of latitude
    final lonStep = 20 / (111320 * math.cos(52.52 * math.pi / 180));
    final centers = <LatLng>[];
    for (var i = 0; i <= 22; i++) {
      final lon = 13.4050 + i * lonStep;
      centers.add(LatLng(52.5200 + jitter, lon));
      centers.add(LatLng(52.5200 - jitter, lon));
    }
    final result = matcher.match(centers);
    expect(result.ratioFor('1001'), greaterThan(0.9));
    expect(result.matchedMeters.containsKey('1004'), isFalse,
        reason: 'the un-ridden parallel way must not complete on wobble');
  });

  test('riding onto the service road switches attribution to it', () {
    // Jittered Main Street wobble for half the walk, then a genuine move
    // onto the service road's centerline (8 m from Main — beyond the switch
    // margin): attribution flips and the service road completes.
    const serviceLat = 52.5200719;
    const jitter = 3.0 / 111320;
    final lonStep = 20 / (111320 * math.cos(52.52 * math.pi / 180));
    final centers = <LatLng>[];
    for (var i = 0; i <= 1; i++) {
      final lon = 13.4050 + i * lonStep;
      centers.add(LatLng(52.5200 + jitter, lon));
      centers.add(LatLng(52.5200 - jitter, lon));
    }
    for (var i = 2; i <= 22; i++) {
      centers.add(LatLng(serviceLat, 13.4050 + i * lonStep));
    }
    final result = matcher.match(centers);
    expect(result.ratioFor('1004'), greaterThan(0.9));
    expect(result.ratioFor('1001'), lessThan(0.9),
        reason: 'Main Street stops accruing at the switch point');
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
