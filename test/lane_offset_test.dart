import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/geo.dart';
import 'package:unvisited/ui/lane_offset.dart';

/// Lane offsetting: a polyline shifted sideways by a ground-meter amount.
/// At lat 45: 0.0001 deg lon ≈ 7.9 m; 0.0002 ≈ 15.7 m.
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

  group('laneOffsetsPerVertex', () {
    const laneMeters = 3.0;
    // Overlap radius 7.5 m: points 7.9 m apart do NOT overlap, 0 apart do.
    const overlap = 7.5;

    test('a single member gets zero offset everywhere', () {
      final pts = [const LatLng(45.0, 9.0), const LatLng(45.0, 9.001)];
      final offsets = laneOffsetsPerVertex(pts,
          selfIndex: 0, membersPoints: [pts], laneMeters: laneMeters, overlapMeters: overlap);
      expect(offsets, [0.0, 0.0]);
    });

    test('two overlapping members split symmetrically; alone = zero', () {
      // Member 0 and 1 share the first vertex; member 1 diverges after.
      final m0 = [const LatLng(45.0, 9.0), const LatLng(45.0, 9.001)];
      final m1 = [
        const LatLng(45.0, 9.0),
        const LatLng(45.001, 9.0), // ~111 m away: alone here
      ];
      final members = [m0, m1];
      final off0 = laneOffsetsPerVertex(m0,
          selfIndex: 0, membersPoints: members, laneMeters: laneMeters, overlapMeters: overlap);
      final off1 = laneOffsetsPerVertex(m1,
          selfIndex: 1, membersPoints: members, laneMeters: laneMeters, overlapMeters: overlap);
      // Shared vertex: ranks 0 and 1 of 2 → -1.5 and +1.5.
      expect(off0[0], closeTo(-laneMeters / 2, 1e-9));
      expect(off1[0], closeTo(laneMeters / 2, 1e-9));
      // Alone vertices: offset 0 — the track sits on its true geometry.
      expect(off0[1], 0.0);
      expect(off1[1], 0.0);
    });

    test('three-way overlap spreads -1, 0, +1 lanes, in member order', () {
      final shared = [const LatLng(45.0, 9.0)];
      final members = [shared, shared, shared];
      for (var i = 0; i < 3; i++) {
        final off = laneOffsetsPerVertex(shared,
            selfIndex: i,
            membersPoints: members,
            laneMeters: laneMeters,
            overlapMeters: overlap);
        expect(off.single, closeTo((i - 1) * laneMeters, 1e-9));
      }
    });

    test('per-vertex offsets apply through offsetLanePointsPerVertex', () {
      final pts = [const LatLng(45.0, 9.0), const LatLng(45.001, 9.0)];
      final out = offsetLanePointsPerVertex(pts, [10.0, 0.0]);
      // First vertex shifts ~10 m east; second stays on the geometry.
      expect(
        haversineMeters(45.0, 9.0, out[0].latitude, out[0].longitude),
        closeTo(10.0, 0.5),
      );
      expect(out[1].latitude, closeTo(45.001, 1e-9));
      expect(out[1].longitude, closeTo(9.0, 1e-9));
    });

    test('empty input and mismatched lengths are safe', () {
      expect(
        laneOffsetsPerVertex(const [],
            selfIndex: 0,
            membersPoints: [const [LatLng(45.0, 9.0)]],
            laneMeters: laneMeters,
            overlapMeters: overlap),
        isEmpty,
      );
      final pts = [const LatLng(45.0, 9.0), const LatLng(45.001, 9.0)];
      expect(offsetLanePointsPerVertex(pts, [1.0]), pts);
    });
  });
}
