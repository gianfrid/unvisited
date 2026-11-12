import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/ui/fog_of_war.dart';

void main() {
  // 1e-5 degrees is about 1.1 m — finer than any cell used below.
  LatLng offset(LatLng p, {double north = 0, double east = 0}) => LatLng(
        p.latitude + north * 1e-5,
        p.longitude + east * 1e-5,
      );

  test('unlockRadiusForCell matches the unlock radius at the base cell',
      () {
    expect(unlockRadiusForCell(baseCellSizeMeters), unlockRadiusMeters);
    expect(unlockRadiusForCell(baseCellSizeMeters * 2),
        unlockRadiusMeters * 2);
  });

  test('empty input unlocks nothing', () {
    expect(unlockCenters(const []), isEmpty);
  });

  test('points within one cell unlock a single center', () {
    // Mid-cell on both axes, so a sub-meter offset cannot cross boundaries.
    const base = LatLng(48.8584, 2.2946);
    final centers = unlockCenters([
      base,
      offset(base, north: 0.5, east: 0.5), // ~0.7 m away: same 12 m cell
    ]);
    expect(centers, hasLength(1));
    expect(centers.single, base, reason: 'the first point in the cell wins');
  });

  test('a corridor of fine points unlocks one circle per cell', () {
    const base = LatLng(52.52, 13.405);
    // 2 m steps northward over 60 m: 8-9 adjacent cells.
    final points = [
      for (var i = 0; i < 30; i++) offset(base, north: i * 2.0),
    ];
    final centers = unlockCenters(points);
    expect(centers.length, allOf(greaterThan(4), lessThan(12)));
    expect(centers.first, base);
  });

  test('consecutive centers stay within two radii, so circles overlap',
      () {
    const base = LatLng(52.52, 13.405);
    final points = [
      for (var i = 0; i < 30; i++) offset(base, north: i * 2.0),
    ];
    final centers = unlockCenters(points)..sort((a, b) {
        return a.latitude.compareTo(b.latitude);
      });
    for (var i = 1; i < centers.length; i++) {
      final gap = (centers[i].latitude - centers[i - 1].latitude) * 111320;
      expect(gap, lessThan(2 * unlockRadiusForCell(baseCellSizeMeters)));
    }
  });

  test('a coarser grid coalesces distant points into fewer centers', () {
    const base = LatLng(48.8584, 2.2945);
    final points = [
      for (var i = 0; i < 10; i++) offset(base, north: i * 4.0),
    ];
    final fine = unlockCenters(points);
    final coarse = unlockCenters(points, cellSizeMeters: 120);
    expect(fine.length, greaterThan(1));
    expect(coarse, hasLength(1), reason: '40 m spread fits one 120 m cell');
  });

  test('revisiting a cell does not unlock it twice', () {
    const base = LatLng(48.8584, 2.2945);
    final centers = unlockCenters([
      base,
      offset(base, north: 100, east: 100),
      base, // out-and-back
    ]);
    expect(centers, hasLength(2));
  });

  test('fogCellSizeFor never drops below the base cell', () {
    expect(fogCellSizeFor(zoom: 19, latitude: 0), baseCellSizeMeters);
    expect(fogCellSizeFor(zoom: 15, latitude: 80), baseCellSizeMeters);
  });

  test('fogCellSizeFor coarsens as the view zooms out', () {
    final world = fogCellSizeFor(zoom: 3, latitude: 0);
    final city = fogCellSizeFor(zoom: 12, latitude: 0);
    final street = fogCellSizeFor(zoom: 17, latitude: 0);
    expect(world, greaterThan(city));
    expect(city, greaterThan(street));
    // Cell sizes come in power-of-two steps above the base cell.
    final ratio = world / baseCellSizeMeters;
    expect(ratio, ratio.roundToDouble(),
        reason: 'steps must be exact doublings of the base cell');
  });
}
