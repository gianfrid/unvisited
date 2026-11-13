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
// Today this input is hand-written (the synthetic test fixture). In the
// slice after next the same tool grows a PBF reader (dev-only deps:
// protobuf + dart_osmpbf) to consume an osmium-filtered Geifabrik extract:
//
//   osmium tags-filter region.osm.pbf w/highway -o roads.osm.pbf
//
// OUTPUT FORMAT (lib/road/road_format.dart is the spec): magic "UNVROADS",
// one version byte (1), a uint32 little-endian JSON payload length, then the
// JSON payload — ways with polyline5-encoded geometry and a z12 bucket index
// mapping "x_y" tile keys to way indices.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

  final wayEntries = <Map<String, dynamic>>[];
  final buckets = <String, List<int>>{};
  for (var i = 0; i < ways.length; i++) {
    final w = ways[i];
    final points = [
      for (final p in (w['points'] as List).cast<List>())
        ((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
    if (points.length < 2) {
      print('warning: way ${w['id']} has fewer than 2 points, skipped');
      continue;
    }
    for (final key in _tilesForWay(points)) {
      buckets.putIfAbsent(key, () => []).add(wayEntries.length);
    }
    wayEntries.add({
      'id': w['id'],
      'class': w['class'] ?? '',
      'name': w['name'] ?? '',
      'pts': encodePolyline5(points),
    });
  }

  final payload = jsonEncode({'ways': wayEntries, 'buckets': buckets});
  final payloadBytes = utf8.encode(payload);
  final out = BytesBuilder()
    ..add(roadMagic)
    ..addByte(roadFormatVersion)
    ..add([
      payloadBytes.length & 0xFF,
      (payloadBytes.length >> 8) & 0xFF,
      (payloadBytes.length >> 16) & 0xFF,
      (payloadBytes.length >> 24) & 0xFF,
    ])
    ..add(payloadBytes);
  final bytes = out.takeBytes();
  File(args[1]).writeAsBytesSync(bytes, flush: true);
  print('${args[1]} written: ${wayEntries.length} ways, '
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
  final keys = <String>{
    roadBucketKeyFor(minLat, minLon),
    roadBucketKeyFor(minLat, maxLon),
    roadBucketKeyFor(maxLat, minLon),
    roadBucketKeyFor(maxLat, maxLon),
    roadBucketKeyFor((minLat + maxLat) / 2, (minLon + maxLon) / 2),
  };
  return keys;
}
