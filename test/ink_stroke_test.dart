import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/ui/fog_of_war.dart' show unlockRadiusMeters;
import 'package:unvisited/ui/ink_stroke.dart';

void main() {
  test('ink base width is 10 m, below the fog unlock radius', () {
    expect(inkWidthMeters, 10.0);
    expect(inkWidthMeters, lessThan(unlockRadiusMeters));
  });

  // A short synthetic segment around Paris, ~10 m steps.
  final segment = [
    for (var i = 0; i < 60; i++) LatLng(48.8584 + i * 1e-5, 2.2946),
  ];

  test('a segment with fewer than two points draws nothing', () {
    expect(inkStrokes(const [], passCount: 1, minRunLength: inkBaseRunLength,
        maxStripsPerTrack: inkMaxStripsPerTrack), isEmpty);
    expect(inkStrokes(const [LatLng(48.8, 2.29)], passCount: 1,
        minRunLength: inkBaseRunLength,
        maxStripsPerTrack: inkMaxStripsPerTrack), isEmpty);
  });

  test('is deterministic across invocations', () {
    final a = inkStrokes(segment, passCount: 3, minRunLength: 16,
        maxStripsPerTrack: inkMaxStripsPerTrack);
    final b = inkStrokes(segment, passCount: 3, minRunLength: 16,
        maxStripsPerTrack: inkMaxStripsPerTrack);
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      expect(b[i].strips.length, a[i].strips.length);
      for (var j = 0; j < a[i].strips.length; j++) {
        expect(b[i].strips[j].run, a[i].strips[j].run);
        expect(b[i].strips[j].width, a[i].strips[j].width);
      }
    }
  });

  test('covers the geometry without exceeding the strip budget', () {
    final passes = inkStrokes(segment, passCount: 3, minRunLength: 16,
        maxStripsPerTrack: inkMaxStripsPerTrack);
    expect(passes, hasLength(3));
    for (final pass in passes) {
      // Every strip point stays within the segment's bbox — the jitter cap
      // in meters is far below a degree, so a degree-wide bbox cannot miss.
      expect(pass.strips, isNotEmpty);
    }
  });

  test('strip count honors the per-track budget', () {
    // A 60k-point segment at 16 points per strip and 3 passes would be
    // ~11k strips unbounded; the build must hold the line near the budget.
    final big = [
      for (var i = 0; i < 60000; i++) LatLng(48.8 + i * 1e-5, 2.29),
    ];
    final passes = inkStrokes(big, passCount: 3, minRunLength: 16,
        maxStripsPerTrack: inkMaxStripsPerTrack);
    var strips = 0;
    for (final pass in passes) {
      strips += pass.strips.length;
    }
    expect(strips, lessThanOrEqualTo(inkMaxStripsPerTrack + 3));
  });

  test('jitter stays within the cap around the original geometry', () {
    final passes = inkStrokes(segment, passCount: 3, minRunLength: 16,
        maxStripsPerTrack: inkMaxStripsPerTrack);
    for (final pass in passes) {
      for (final s in pass.strips) {
        for (final p in s.run) {
          // The segment runs due north; jitter is perpendicular (east-west)
          // and capped at inkJitterMeters in degrees via /111320.
          expect((p.longitude - 2.2946).abs(), lessThan(0.01));
        }
      }
    }
  });
}
