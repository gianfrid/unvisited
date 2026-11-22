import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'track_colors.dart';

/// Simulated ink strokes for the fog overlay's "ink" display style.
///
/// Deterministic by construction: every jitter and width value is hashed
/// from the quantized point coordinates plus a per-point salt (never a
/// live RNG), so rebuilds never flicker. Geometry is bounded: strips
/// lengthen before points are ever dropped.

/// Points per width strip at the finest band; the run-length budget rule
/// (below) lengthens strips, never shortens them, when tracks get big.
const inkBaseRunLength = 16;

/// Perpendicular jitter cap, in meters: sub-pixel even at mid zoom.
const inkJitterMeters = 1.5;

/// Base stroke width, in ground meters, of the ink style's core pass —
/// deliberately below the fog circles' 15 m unlock radius so ink and
/// circles read differently. Pass width factors multiply this (bleed ≈
/// 22 m, core ≈ 7 m); the caller converts to screen pixels via the map's
/// ground resolution.
const inkWidthMeters = 10.0;

/// Per-track polyline budget across all passes: when a band's geometry
/// exceeds it, strip lengths double (and the floor degrades to one strip
/// per pass) rather than drop points.
const inkMaxStripsPerTrack = 1000;

/// One strip of an ink pass: a polyline run at its own wobbled width.
typedef InkStrip = ({List<LatLng> run, double width});

/// One layered pass of a simulated ink stroke: consecutive strips of the
/// segment's geometry, each at its own wobbled width. [width] is the
/// pass's base width, [alpha] its ink-opacity multiplier.
class InkPass {
  InkPass(this.strips, this.width, this.alpha);
  final List<InkStrip> strips;
  final double width;
  final double alpha;
}

/// Simulated ink strokes for one track segment: [passCount] layered passes
/// (bleed under mid under core), each cut into strips of [minRunLength]
/// points at hash-wobbled widths. Deterministic; empty for a segment with
/// fewer than two points.
List<InkPass> inkStrokes(
  List<LatLng> points, {
  required int passCount,
  required int minRunLength,
  required int maxStripsPerTrack,
}) {
  if (points.length < 2) return const [];
  // The run-length budget: strips lengthen before geometry is ever
  // dropped, so the total polyline count converges on the budget no
  // matter how long the segment is (the plain-polyline floor).
  final runLength = math.max(
    minRunLength,
    ((points.length - 1) * passCount / maxStripsPerTrack).ceil(),
  );
  final passes = <InkPass>[];
  for (var pass = 0; pass < passCount; pass++) {
    final strips = <InkStrip>[];
    var i = 0;
    while (i + 1 < points.length) {
      final end = math.min(i + runLength, points.length - 1);
      final wobble =
          0.8 + 0.4 * _unit01(points[i], pass * 0x27D4EB2F + end);
      strips.add((
        run: <LatLng>[
          for (var j = i; j <= end; j++) _jitter(points, j, pass),
        ],
        width: minRunLength * wobble,
      ));
      i = end;
    }
    passes.add(InkPass(
      strips,
      inkPassWidthFactors[math.min(pass, inkPassWidthFactors.length - 1)],
      inkPassAlphas[math.min(pass, inkPassAlphas.length - 1)],
    ));
  }
  return passes;
}

/// Unit vector perpendicular to the local segment direction at index [j]
/// of [points], longitude pre-widened by the reference cosine so offsets
/// are near-isotropic (as in fog_of_war.dart's grid).
(double, double) _perpendiculars(List<LatLng> points, int j) {
  final prev = points[math.max(0, j - 1)];
  final next = points[math.min(points.length - 1, j + 1)];
  final dLat = next.latitude - prev.latitude;
  final dLon = (next.longitude - prev.longitude) / 0.7071067811865476;
  final len = math.sqrt(dLat * dLat + dLon * dLon);
  if (len < 1e-12) return (1.0, 0.0);
  return (-dLon / len, dLat / len);
}

/// Jitters one point perpendicular to its local segment direction by at
/// most ±[inkJitterMeters], deterministically from its coordinates.
LatLng _jitter(List<LatLng> points, int j, int salt) {
  final p = points[j];
  final mag = inkJitterMeters * (2 * _unit01(p, salt) - 1);
  final (nLat, nLon) = _perpendiculars(points, j);
  return LatLng(
    p.latitude + nLat * mag / 111320.0,
    p.longitude + nLon * mag / (111320.0 * 0.7071067811865476),
  );
}

/// Uniform [0, 1) from a point's quantized coordinates plus a salt.
double _unit01(LatLng p, int salt) {
  var h = 0x811C9DC5;
  for (final v in [
    (p.latitude * 1e5).round(),
    (p.longitude * 1e5).round(),
    salt,
  ]) {
    for (var shift = 0; shift < 32; shift += 8) {
      h = (h ^ ((v >> shift) & 0xFF)) & 0xFFFFFFFF;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
  }
  return (h & 0xFFFFFF) / 0x1000000;
}
