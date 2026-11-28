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

/// One representative point per newly occupied grid cell, claiming into
/// [seen] (cell key -> the point that claimed it). A cell already
/// claimed by an earlier caller's points is skipped, so ground shared by
/// several tracks unlocks exactly once — with many overlapping tracks
/// the overlay's cost stays bounded by the union's area, not by the
/// number of tracks covering it. Returned points are actual track
/// points, not grid centers, so coordinates stay exact. Callers pass
/// one [seen] map across all their tracks in a stable order; the first
/// track through a cell wins it.
List<LatLng> claimUnlockCenters(
  Iterable<LatLng> points, {
  required Map<(int, int), LatLng> seen,
  double cellSizeMeters = baseCellSizeMeters,
}) {
  final degLat = cellSizeMeters / _metersPerDegree;
  final degLon = cellSizeMeters / (_metersPerDegree * _lonReferenceCos);
  final out = <LatLng>[];
  for (final p in points) {
    final key = (
      (p.latitude / degLat).floor(),
      (p.longitude / degLon).floor(),
    );
    if (seen.containsKey(key)) continue;
    seen[key] = p;
    out.add(p);
  }
  return out;
}

/// One representative point per occupied grid cell (the first to land in
/// it), for a grid with the given cell edge. Returned points are actual
/// track points, not grid centers, so coordinates stay exact.
List<LatLng> unlockCenters(Iterable<LatLng> points,
    {double cellSizeMeters = baseCellSizeMeters}) {
  return claimUnlockCenters(
    points,
    seen: <(int, int), LatLng>{},
    cellSizeMeters: cellSizeMeters,
  );
}

/// Splits [segments] wherever they enter grid ground [seen] already
/// holds: a cell claimed by an earlier caller's points ends the current
/// run (keeping one dropped point as the handoff, so a line resuming at
/// the edge of covered ground stays continuous with the claiming
/// track's line instead of notching), and the next unclaimed cell
/// starts a new run that likewise reaches one point back. Interior
/// points of a cell the run itself owns are kept as-is, so a track's
/// own geometry stays smooth — only ground another point already
/// claimed is dropped, which includes the track's own out-and-back
/// revisits (a revisited cell is not drawn twice, like the circles).
/// A fully covered segment drops out entirely; a trailing run needs
/// two points to be drawable. Cell math matches [claimUnlockCenters],
/// so a skipped point's neighborhood is already painted by the
/// claiming track — the drawn union is unchanged by construction, only
/// the overdraw is gone.
List<List<LatLng>> dedupeSegments(
  Iterable<List<LatLng>> segments, {
  required Map<(int, int), LatLng> seen,
  double cellSizeMeters = baseCellSizeMeters,
}) {
  final degLat = cellSizeMeters / _metersPerDegree;
  final degLon = cellSizeMeters / (_metersPerDegree * _lonReferenceCos);
  final out = <List<LatLng>>[];
  for (final seg in segments) {
    List<LatLng>? run;
    LatLng? lastDropped;
    (int, int)? prevCell;
    for (final p in seg) {
      final key = (
        (p.latitude / degLat).floor(),
        (p.longitude / degLon).floor(),
      );
      final sameCell = key == prevCell;
      prevCell = key;
      if (run != null && sameCell) {
        run.add(p); // the run owns this cell: interior point, keep it
        continue;
      }
      if (seen.containsKey(key)) {
        if (run != null) {
          run.add(p); // one-point overlap into covered ground
          if (run.length > 1) out.add(run);
          run = null;
        }
        lastDropped = p;
        continue;
      }
      seen[key] = p;
      if (run == null) {
        run = [?lastDropped, p];
      } else {
        run.add(p);
      }
    }
    if (run != null && run.length > 1) out.add(run);
  }
  return out;
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
