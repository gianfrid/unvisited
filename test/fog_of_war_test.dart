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

  // --- Cross-track claim dedup ------------------------------------------
  //
  // The base cell is 12 m; offset() steps are chosen so consecutive
  // points cross cell boundaries where the test needs them to.

  test('a shared seen map unlocks shared ground exactly once', () {
    const base = LatLng(52.52, 13.405);
    final seen = <(int, int), LatLng>{};
    final first = claimUnlockCenters([
      for (var i = 0; i < 30; i++) offset(base, north: i * 2.0),
    ], seen: seen);
    final second = claimUnlockCenters([
      // The same corridor, ridden again: every cell is already claimed.
      for (var i = 0; i < 30; i++) offset(base, north: i * 2.0, east: 0.5),
    ], seen: seen);
    expect(first, isNotEmpty);
    expect(
        second, isEmpty, reason: 'ground already unlocked is not re-unlocked');

    // A fresh detour east of the corridor still unlocks its own cells.
    final third = claimUnlockCenters([
      offset(base, north: 30 * 2.0, east: 40.0), // ~44 m off the corridor
    ], seen: seen);
    expect(third, hasLength(1));
  });

  test('dedupeSegments drops a fully covered segment', () {
    const base = LatLng(52.52, 13.405);
    final seen = <(int, int), LatLng>{};
    claimUnlockCenters([
      for (var i = 0; i < 30; i++) offset(base, north: i * 2.0),
    ], seen: seen);
    final out = dedupeSegments([
      [for (var i = 0; i < 30; i++) offset(base, north: i * 2.0, east: 0.5)],
    ], seen: seen);
    expect(out, isEmpty);
  });

  test('dedupeSegments splits at covered runs with one-point handoffs', () {
    const base = LatLng(52.52, 13.405);
    // Cell boundaries fall at absolute grid positions, so the test
    // asserts on cells, not point indexes.
    final degLat = baseCellSizeMeters / 111320.0;
    int latCell(LatLng p) => (p.latitude / degLat).floor();
    // Track A claims the middle stretch of a northward corridor.
    final covered = [
      for (var i = 10; i < 20; i++) offset(base, north: i * 2.0),
    ];
    final seen = <(int, int), LatLng>{};
    claimUnlockCenters(covered, seen: seen);
    // Track B rides the whole corridor: the middle is A's, the ends are
    // B's — kept as two runs reaching one point into the covered part.
    final out = dedupeSegments([
      [for (var i = 0; i < 30; i++) offset(base, north: i * 2.0)],
    ], seen: seen);
    expect(out, hasLength(2));
    final south = out.first, north = out.last;
    expect(latCell(south.last), latCell(covered.first),
        reason: 'the run ends one point into the covered stretch');
    expect(latCell(south[south.length - 2]), lessThan(latCell(covered.first)));
    expect(latCell(north.first), latCell(covered.last),
        reason: 'the next run starts one point back inside it');
    expect(latCell(north[1]), greaterThan(latCell(covered.last)));
    expect(south.length, greaterThan(2));
    expect(north.length, greaterThan(2));
  });

  test('dedupeSegments keeps a unique detour intact', () {
    const base = LatLng(52.52, 13.405);
    final seen = <(int, int), LatLng>{};
    // Track A: a northward corridor.
    claimUnlockCenters([
      for (var i = 0; i < 20; i++) offset(base, north: i * 6.0),
    ], seen: seen);
    // Track B: the corridor's claimed start, then a wide eastward
    // detour of points no other track covers.
    final out = dedupeSegments([
      [
        base,
        for (var i = 1; i <= 6; i++) offset(base, east: i * 20.0),
      ],
    ], seen: seen);
    expect(out, hasLength(1));
    final run = out.single;
    expect(run.first, base,
        reason: 'the handoff keeps the last dropped point');
    expect(run, hasLength(7), reason: 'handoff point + the whole detour');
  });

  test('kept points in dedupeSegments claim their cells for later segments',
      () {
    const base = LatLng(52.52, 13.405);
    final seen = <(int, int), LatLng>{};
    final first = dedupeSegments([
      [for (var i = 0; i < 10; i++) offset(base, north: i * 4.0)],
    ], seen: seen);
    expect(first, isNotEmpty);
    final second = dedupeSegments([
      [for (var i = 0; i < 10; i++) offset(base, north: i * 4.0, east: 0.5)],
    ], seen: seen);
    expect(second, isEmpty, reason: 'the first segment claimed the cells');
  });
}
