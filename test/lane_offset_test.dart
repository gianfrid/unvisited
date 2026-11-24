import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/geo.dart';
import 'package:unvisited/ui/lane_offset.dart';

/// Lane offsetting: a polyline shifted sideways by a ground-meter amount.
void main() {
  // A north-south segment at lat 45, lon 9: 0.001 deg lat ≈ 111.32 m.
  final northSouth = [
    const LatLng(45.0, 9.0),
    const LatLng(45.001, 9.0),
  ];

  test('a straight segment shifts sideways by the offset, not along it', () {
    final out = offsetLanePoints(northSouth, 10.0);
    expect(out, hasLength(2));
    // Travel is due north, so the perpendicular is due east/west: latitude
    // unchanged, longitude shifted.
    expect(out[0].latitude, closeTo(45.0, 1e-9));
    expect(out[1].latitude, closeTo(45.001, 1e-9));
    final shiftMeters = haversineMeters(
        45.0, 9.0, out[0].latitude, out[0].longitude);
    expect(shiftMeters, closeTo(10.0, 0.5));
    // Both endpoints shift the same way: the segment stays parallel.
    final shifted = haversineMeters(
        out[0].latitude, out[0].longitude, out[1].latitude, out[1].longitude);
    expect(shifted, closeTo(111.32, 1.0));
  });

  test('negative offset goes to the other side', () {
    final right = offsetLanePoints(northSouth, 10.0);
    final left = offsetLanePoints(northSouth, -10.0);
    expect(
      haversineMeters(
          right[0].latitude, right[0].longitude, left[0].latitude, left[0].longitude),
      closeTo(20.0, 1.0),
    );
  });

  test('zero offset and degenerate input are identity', () {
    expect(offsetLanePoints(northSouth, 0.0), northSouth);
    final single = [const LatLng(45.0, 9.0)];
    expect(offsetLanePoints(single, 10.0), single);
    // A zero-length segment has no direction of its own: both coincident
    // points shift together (borrowing the default bearing), staying a
    // single point.
    final dup = [const LatLng(45.0, 9.0), const LatLng(45.0, 9.0)];
    final out = offsetLanePoints(dup, 10.0);
    expect(out[0], out[1]);
    expect(
      haversineMeters(45.0, 9.0, out[0].latitude, out[0].longitude),
      closeTo(10.0, 0.5),
    );
  });

  test('a corner stays roughly equidistant from both legs', () {
    // An L: north then east. The corner vertex is pushed along the average
    // of the two perpendiculars (southeast-ish), so its distance to the
    // original corner is the offset.
    final corner = [
      const LatLng(45.0, 9.0),
      const LatLng(45.001, 9.0),
      const LatLng(45.001, 9.001),
    ];
    final out = offsetLanePoints(corner, 10.0);
    final d = haversineMeters(
        corner[1].latitude, corner[1].longitude, out[1].latitude, out[1].longitude);
    expect(d, closeTo(10.0, 0.5));
    // And the offset direction at the corner is the diagonal, not aligned
    // with either leg's perpendicular alone.
    final bearing = initialBearingDeg(
        corner[1].latitude, corner[1].longitude, out[1].latitude, out[1].longitude);
    expect(bearing, closeTo(135.0, 15.0)); // SE for a north-then-east L
  });

  test('offset scales linearly with the meters argument', () {
    final one = offsetLanePoints(northSouth, 5.0);
    final two = offsetLanePoints(northSouth, 10.0);
    final d = haversineMeters(
        one[0].latitude, one[0].longitude, two[0].latitude, two[0].longitude);
    expect(d, closeTo(5.0, 0.5));
    expect(math.max(0, 1), 1, reason: 'math import used');
  });
}
