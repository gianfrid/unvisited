import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Fog-of-war exploration math.
///
/// Every track point "unlocks" a small circular area around it, the way
/// moving through a fog-of-war map reveals terrain in games. Drawing one
/// circle per GPS point does not scale to a real catalog, so points are
/// coalesced into a square grid: one unlock circle per occupied cell,
/// centered on the first point that landed in it. Consecutive GPS points
/// are seconds apart and land in adjacent cells, and neighboring circles
/// overlap by construction, so a track reads as one continuous revealed
/// corridor rather than a dotted bead line.

/// Radius, in meters, of the area a single track point unlocks.
const unlockRadiusMeters = 15.0;

/// Ground meters per degree of latitude (WGS-84 mean value).
const _metersPerDegree = 111320.0;

/// Longitude cells shrink with the cosine of the latitude; a fixed 45°
/// reference keeps cells roughly square across most inhabited latitudes.
const _lonReferenceCos = 0.7071067811865476;

/// The grid cell edge, in meters, at the finest detail level. Keyed to the
/// unlock radius so that circles of adjacent cells always overlap (see
/// [unlockRadiusForCell]).
const baseCellSizeMeters = unlockRadiusMeters / 1.25;

/// Unlock-circle radius for a grid with the given cell edge. Points in
/// neighboring cells can sit up to almost two cells apart at their nearest
/// corners; a radius of 1.25 cells closes that worst-case gap, so the
/// union of circles is a continuous corridor.
double unlockRadiusForCell(double cellSizeMeters) => cellSizeMeters * 1.25;

/// The ground resolution (meters per screen pixel) of web Mercator at the
/// given latitude and (fractional) zoom level.
double groundResolution({required double zoom, required double latitude}) =>
    156543.03 *
    math.cos(latitude * math.pi / 180) /
    math.pow(2, zoom);

/// Grid cell edge to use for [zoom] and [latitude]: the base cell once
/// circles would be more than a few pixels wide, doubling as the view
/// zooms out. Keeps far-overview rendering cheap — a whole-hobby catalog
/// collapses to a few hundred blobs at world zoom instead of hundreds of
/// thousands of sub-pixel circles.
double fogCellSizeFor({required double zoom, required double latitude}) {
  final target = groundResolution(zoom: zoom, latitude: latitude) * 2.4;
  if (target <= baseCellSizeMeters) return baseCellSizeMeters;
  final doublings =
      (math.log(target / baseCellSizeMeters) / math.ln2).ceil();
  return baseCellSizeMeters * math.pow(2, doublings).toDouble();
}

/// One representative point per occupied grid cell (the first to land in
/// it), for a grid with the given cell edge. Returned points are actual
/// track points, not grid centers, so coordinates stay exact.
List<LatLng> unlockCenters(Iterable<LatLng> points,
    {double cellSizeMeters = baseCellSizeMeters}) {
  final degLat = cellSizeMeters / _metersPerDegree;
  final degLon = cellSizeMeters / (_metersPerDegree * _lonReferenceCos);
  final seen = <(int, int), LatLng>{};
  for (final p in points) {
    final key = (
      (p.latitude / degLat).floor(),
      (p.longitude / degLon).floor(),
    );
    seen.putIfAbsent(key, () => p);
  }
  return List.of(seen.values);
}

// --- Display styles -------------------------------------------------------

/// The exploration overlay's display styles, as persisted in the settings.
const fogStyles = <String>['circles', 'polyline', 'ink'];

/// The fog display style a fresh install starts with.
const defaultFogStyle = 'circles';

/// The normalized fog display style: unknown stored values fall back to
/// [defaultFogStyle], so a hand-edited index can never break rendering.
String fogStyleOrDefault(String? style) =>
    fogStyles.contains(style) ? style! : defaultFogStyle;

/// Splits track points into drawable segments, breaking wherever two
/// consecutive points are farther apart than [maxGapMeters] (a `<trkseg>`
/// break, a paused recording's resume, a teleport) so no artificial line
/// connects across the gap. Runs of two or more points become segments.
List<List<LatLng>> splitTrackSegments(
  Iterable<LatLng> points, {
  double maxGapMeters = 100.0,
}) {
  final segs = <List<LatLng>>[];
  List<LatLng>? current;
  LatLng? prev;
  final maxDeg = maxGapMeters / _metersPerDegree;
  for (final p in points) {
    if (current == null ||
        prev == null ||
        (p.latitude - prev.latitude).abs() > maxDeg ||
        (p.longitude - prev.longitude).abs() / _lonReferenceCos > maxDeg) {
      // Latitude-approx gap test with a cosine-widened longitude bound:
      // cheap, and only ever splits a little late (rarely splits one
      // segment too many) — never joins across a real gap.
      current = [p];
      segs.add(current);
    } else {
      current.add(p);
    }
    prev = p;
  }
  return [for (final s in segs) if (s.length > 1) s];
}

/// Keeps every [k]-th point of [points] (always the first and adjusted to
/// keep the last). The line-styles' zoom-band decimation: drawing geometry
/// only ever smooths to within one fog cell, the same contract a coarser
/// grid gives the circles.
List<LatLng> decimate(List<LatLng> points, int k) {
  if (k <= 1 || points.length < 3) return points;
  final out = <LatLng>[
    for (var i = 0; i < points.length; i += k) points[i],
  ];
  if (out.last != points.last) out.add(points.last);
  return out;
}
