// ignore_for_file: avoid_print
// Builds an Unvisited road file from a JSON way list.
//
// Run with: dart run tool/build_roads.dart <ways.json> <output.roads>
//
// Input JSON shape:
// ```json
// {"ways": [{"id": "123", "class": "residential", "name": "Main Street",
//            "points": [[52.52, 13.405], [52.52, 13.41]]}]}
// ```
//
// Today this input is hand-written (the synthetic test fixture). A later
// slice grows the same tool a PBF reader (dev-only deps: protobuf +
// dart_osmpbf) to consume an osmium-filtered Geofabrik extract:
//
//   osmium tags-filter region.osm.pbf w/highway -o roads.osm.pbf
//
// Output format: see lib/road/road_format.dart (version 2 — a JSON bucket
// directory followed by one payload blob per z12 bucket, so the app opens a
// region file in milliseconds and parses only the buckets a track touches).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:unvisited/road/road_format.dart';

void main(List<String> args) {
  if (args.length != 2) {
    print('usage: dart run tool/build_roads.dart <ways.json> <output.roads>');
    exit(2);
  }
  final source = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final ways = (source['ways'] as List).cast<Map>();
  if (ways.isEmpty) {
    print('error: no ways in ${args[0]}');
    exit(1);
  }
  buildRoadFile(ways, args[1]);
}

/// Encodes [ways] (id/class/name/points maps as in the JSON source) into
/// the road file at [outPath]. Also the entry point for other tools (the
/// benchmark builds its synthetic city through this) and, in a later
/// slice, for the PBF reader.
void buildRoadFile(List<Map> ways, String outPath) {
  final buckets = <String, List<Map<String, dynamic>>>{};
  var skipped = 0;
  for (final w in ways) {
    final points = [
      for (final p in (w['points'] as List).cast<List>())
        ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    if (points.length < 2) {
      skipped++;
      continue;
    }
    final entry = {
      'id': '${w['id']}',
      'class': w['class'] ?? '',
      'name': w['name'] ?? '',
      'pts': encodePolyline5(points),
    };
    // A way registers in every bucket its bbox touches (the same
    // conservative rule the matcher's own index uses).
    for (final key in _tilesForWay(points)) {
      buckets.putIfAbsent(key, () => []).add(entry);
    }
  }
  if (skipped > 0) {
    print('warning: skipped $skipped ways with fewer than 2 points');
  }
  final bytes = encodeRoadFile(buckets);
  File(outPath).writeAsBytesSync(bytes, flush: true);
  print('$outPath written: ${ways.length - skipped} ways, '
      '${buckets.length} buckets, ${bytes.length} bytes');
}

/// Every z12 tile a way's bounding box touches. Bbox-based (not per-point)
/// so a way crossing a corner registers in all tiles its corridor spans.
Set<String> _tilesForWay(List<(double, double)> points) {
  final lats = points.map((p) => p.$1);
  final lons = points.map((p) => p.$2);
  final minLat = lats.reduce(math.min);
  final maxLat = lats.reduce(math.max);
  final minLon = lons.reduce(math.min);
  final maxLon = lons.reduce(math.max);
  return <String>{
    roadBucketKeyFor(minLat, minLon),
    roadBucketKeyFor(minLat, maxLon),
    roadBucketKeyFor(maxLat, minLon),
    roadBucketKeyFor(maxLat, maxLon),
    roadBucketKeyFor((minLat + maxLat) / 2, (minLon + maxLon) / 2),
  };
}
