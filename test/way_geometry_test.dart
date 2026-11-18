import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/road/way_geometry.dart';

void main() {
  // Main Street's geometry from the synthetic fixture: an exact
  // east-west line at lat 52.5200, ~339 m end to end.
  final mainStreet = const [
    LatLng(52.5200, 13.4050),
    LatLng(52.5200, 13.4100),
  ];
  final lengthM = const Distance().distance(mainStreet.first, mainStreet.last);

  test('mergeIntervals unions overlapping and sorts out-of-order', () {
    final merged = mergeIntervals([
      [200, 300],
      [0, 150],
      [140, 210],
    ]);
    // 140..300 coalesce; 0..150 overlaps into one span from 0: the
    // intervals all chain into a single union here.
    expect(merged.length, 1);
    expect(merged.single[0], 0);
    expect(merged.single[1], 300);
  });

  test('mergeIntervals keeps disjoint intervals disjoint', () {
    final merged = mergeIntervals([
      [50, 60],
      [0, 10],
    ]);
    expect(merged.length, 2);
    expect(merged[0], [0, 10]);
    expect(merged[1], [50, 60]);
  });

  test('cutGeometry interpolates endpoints inside segments', () {
    final half = cutGeometry(mainStreet, 0, lengthM / 2);
    expect(half.length, 2);
    expect(half.first, mainStreet.first);
    expect(half.last.longitude, closeTo(13.4075, 1e-4));
  });

  test('offsetOf walks meters along the geometry', () {
    final (midway, _) = offsetOf(mainStreet, const LatLng(52.5200, 13.4075));
    expect(midway, closeTo(lengthM / 2, 1));
  });

  test('unvisitedStretches: no corridors yields the whole way', () {
    final stretches = unvisitedStretches(mainStreet, const []);
    expect(stretches.length, 1);
    expect(
      const Distance().distance(
          stretches.single.first, stretches.single.last),
      closeTo(lengthM, 2),
    );
  });

  test('unvisitedStretches: a full corridor empties the way', () {
    final stretches = unvisitedStretches(mainStreet, [
      List.of(mainStreet),
    ]);
    expect(stretches, isEmpty);
  });

  test('unvisitedStretches: a mid-way corridor leaves both ends dark',
      () async {
    final corridor = cutGeometry(mainStreet, lengthM * 0.25, lengthM * 0.75);
    final stretches = unvisitedStretches(mainStreet, [corridor]);
    expect(stretches.length, 2);
    final dark = stretches.fold<double>(
        0, (sum, s) => sum + const Distance().distance(s.first, s.last));
    expect(dark, closeTo(lengthM / 2, lengthM * 0.02));
  });

  test('unvisitedStretches: disjoint visits leave the walked gap dark',
      () {
    final walkedA = cutGeometry(mainStreet, 0, lengthM * 0.2);
    final walkedB = cutGeometry(mainStreet, lengthM * 0.8, lengthM);
    final stretches = unvisitedStretches(mainStreet, [walkedA, walkedB]);
    expect(stretches.length, 1);
    final gap = stretches.single;
    expect(
      const Distance().distance(gap.first, gap.last),
      closeTo(lengthM * 0.6, lengthM * 0.02),
    );
  });

  test('unvisitedStretches tolerates a drifted corridor from a re-extract',
      () {
    // The corridor was cut from last year's geometry, a couple of
    // meters off today's: nearest-still-wins projection must map it
    // to the mid-way interval, not somewhere unrelated.
    final corridor = [
      const LatLng(52.52002, 13.4060),
      const LatLng(52.52002, 13.4080),
    ];
    final stretches = unvisitedStretches(mainStreet, [corridor]);
    expect(stretches.length, 2);
    final walked = stretches.fold<double>(0,
        (sum, s) => sum + const Distance().distance(s.first, s.last));
    // The corridor spans offsets [0.2, 0.6] of the way: both dark ends
    // together are the remaining 0.6 of the length.
    expect(walked, closeTo(lengthM * 0.6, lengthM * 0.05));
  });

  test('unvisitedStretches: a one-point way draws nothing', () {
    expect(unvisitedStretches(const [LatLng(52.52, 13.405)], const []),
        isEmpty);
  });
}
