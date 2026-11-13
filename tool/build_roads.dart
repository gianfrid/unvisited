// ignore_for_file: avoid_print
// Builds an Unvisited road file from either input:
//
//   dart run tool/build_roads.dart <ways.json>      <output.roads>
//   dart run tool/build_roads.dart <region.osm.pbf> <output.roads>
//
// The input is detected by content, not extension: an OSM PBF file opens
// with an "OSMHeader" blob (see tool/pbf_reader.dart's sniff); anything
// else is read as the JSON way list. An osmium-filtered extract is the
// recommended pipeline — filtering to highway ways plus their referenced
// nodes:
//
//   osmium tags-filter region.osm.pbf w/highway -o roads.osm.pbf
//
// The reader also accepts the *unfiltered* extract (it only keeps ways
// with a highway tag, but then needs a second pass to collect the nodes
// those ways reference, at the cost of reading the file twice — and the
// input being much larger). Both paths stream, so memory stays bounded by
// the highway-referenced node count, not the file.
//
// JSON way-list shape (what the synthetic test fixture uses):
// ```json
// {"ways": [{"id": "123", "class": "residential", "name": "Main Street",
//            "points": [[52.52, 13.405], [52.52, 13.41]]}]}
// ```
//
// Output format: see lib/road/road_format.dart (version 2 — a JSON bucket
// directory followed by one payload blob per z12 bucket, so the app opens a
// region file in milliseconds and parses only the buckets a track touches).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:unvisited/road/road_format.dart';

import 'pbf_reader.dart';

void main(List<String> args) {
  if (args.length != 2) {
    print('usage: dart run tool/build_roads.dart <input> <output.roads>');
    print('  input: ways JSON, or an (osmium-filtered) .osm.pbf extract');
    exit(2);
  }
  // Content sniff: an OSM PBF's "OSMHeader" marker sits at offset 4 (after
  // the first frame's big-endian length), so 20 bytes decide the format.
  final head = <int>[...File(args[0]).openSync().readSync(20)];
  if (head.length < 19) {
    print('error: ${args[0]} is too short to be either input format');
    exit(1);
  }
  final List<Map> ways;
  if (looksLikeOsmPbf(head)) {
    print('reading OSM PBF ${args[0]} ...');
    final stopwatch = Stopwatch()..start();
    final extraction = extractHighwayWays(args[0], onWarning: print);
    stopwatch.stop();
    print(
      'scanned ${extraction.totalWays} ways '
      '(${extraction.highwayWays} highway-tagged) in '
      '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s; '
      'kept ${extraction.ways.length} with geometry'
      '${extraction.shortWays > 0 ? ', ${extraction.shortWays} too short' : ''}'
      '${extraction.missingNodeWays > 0 ? ', ${extraction.missingNodeWays} missing nodes' : ''}',
    );
    ways = extraction.ways;
  } else {
    final source = jsonDecode(File(args[0]).readAsStringSync()) as Map;
    ways = (source['ways'] as List).cast<Map>();
  }
  if (ways.isEmpty) {
    print('error: no highway ways in ${args[0]}');
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
  print(
    '$outPath written: ${ways.length - skipped} ways, '
    '${buckets.length} buckets, ${bytes.length} bytes',
  );
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
