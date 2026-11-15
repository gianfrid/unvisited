// ignore_for_file: avoid_print
// Development benchmark for one road-region file — the measured numbers
// behind the bucket-payload and Rust-core decisions (research report
// docs/offline-road-matching-for-unvisited-research-report.md).
//
// Pure Dart, no Flutter; run through the desktop CLI
// (`dart tool/bench_roads.dart --roads <file>`). It lives in tool/ (not
// lib/) because it is dev tooling: it used to sit in lib/ to let a
// profile-mode in-app trigger run it on a device, which was dropped in
// favor of the CLI.
//
// What it measures, in the order a real session costs it:
//  1. open — the directory JSON parse (the only whole-file cost at launch);
//  2. scan — a cold parse of *every* bucket payload at region scale
//     (per-bucket ms, average and max, total bytes and ways): the worst
//     case the lazy-loading promise could approach, and the per-bucket
//     costs a mid-range device must hide;
//  3. match — a serpentine walk inside the densest bucket, first cold
//     (bucket parse + segment index build + match) then warm.
//
// Results are plain maps of numbers (no custom result class to keep that
// portable).
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'package:unvisited/road/road_matcher.dart';
import 'package:unvisited/road/road_store.dart';

/// Formats a [benchRoadStore]/[runRoadBench] result as the console summary
/// the CLI and the in-app profile run both print.
String benchReport(Map<String, Object> r) {
  final opens = r['openMs'] as List<double>;
  final open = opens.isEmpty
      ? 'n/a (in-memory store)'
      : opens.map((t) => t.toStringAsFixed(1)).join(' / ');
  final warms = r['warmMs'] as List<double>;
  final warmAvg = warms.fold(0.0, (a, b) => a + b) / warms.length;
  final warmMin = warms.fold<double>(double.infinity, math.min);
  return [
    'road file: ${_mb(r['fileBytes'] as int)} MB, '
        'directory ${((r['directoryBytes'] as int) / 1024).toStringAsFixed(0)} kB',
    '${r['buckets']} buckets, ${r['ways']} ways, '
        '${_mb(r['payloadBytes'] as int)} MB payload JSON',
    'open (parse + index): $open ms',
    'payload scan: ${(r['scanMs'] as double).toStringAsFixed(0)} ms '
        '(bucket avg ${(r['avgBucketMs'] as double).toStringAsFixed(1)} ms, '
        'max ${(r['maxBucketMs'] as double).toStringAsFixed(1)} ms)',
    'densest bucket ${r['densestKey']}: ${r['densestWays']} ways, '
        'cold parse ${(r['densestMs'] as double).toStringAsFixed(1)} ms',
    'walk: ${r['walkPoints']} points, '
        '${(r['walkKm'] as double).toStringAsFixed(1)} km',
    'match cold: ${(r['coldMs'] as double).toStringAsFixed(0)} ms '
        '(${r['matchedWays']} ways touched, ${r['corridors']} corridors, '
        '${(r['matchedMeters'] as double).toStringAsFixed(0)} m matched)',
    'match warm: avg ${warmAvg.toStringAsFixed(1)} ms / '
        'min ${warmMin.toStringAsFixed(1)} ms over ${warms.length} runs',
  ].join('\n');
}

String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(2);

/// The benchmark core against an already-open store (tests pass their own;
/// [runRoadBench] wraps it with a timed open). Returns plain numbers —
/// [benchReport] renders them. [walkOrigin] overrides the default walk
/// location (the center of the densest bucket); pass one in tests to aim
/// the walk at known geometry.
Map<String, Object> benchRoadStore(
  RoadStore road, {
  int fileBytes = 0,
  List<double> openMs = const [],
  int walkPoints = 2000,
  double stepMeters = 5.0,
  LatLng? walkOrigin,
  int warmRuns = 5,
}) {
  final keys = road.bucketKeys.toList()..sort();

  // Cold scan over every payload in key order: the aggregate whole-region
  // cost plus the per-bucket distribution (avg, max, densest).
  var payloadBytes = 0;
  var wayCount = 0;
  var parseSumMs = 0.0;
  var maxBucketMs = 0.0;
  var denseKey = '';
  var denseWays = 0;
  var denseMs = 0.0;
  final scan = Stopwatch()..start();
  for (final key in keys) {
    final w = Stopwatch()..start();
    final bucket = road.bucketByKey(key);
    w.stop();
    final ms = w.elapsedMicroseconds / 1000;
    parseSumMs += ms;
    if (ms > maxBucketMs) maxBucketMs = ms;
    wayCount += bucket.length;
    payloadBytes += road.bucketPayloadBytes(key);
    if (bucket.length > denseWays) {
      denseWays = bucket.length;
      denseKey = key;
      denseMs = ms;
    }
  }
  final scanMs = scan.elapsedMicroseconds / 1000.0;
  final avgBucketMs = keys.isEmpty ? 0.0 : parseSumMs / keys.length;

  // Serpentine walk (densest bucket unless overridden), then match cold and
  // warm — cold includes the segment index build, warm reuses it.
  final origin = walkOrigin ?? (denseKey.isEmpty ? null : _bucketCenter(denseKey));
  final walk = origin == null
      ? <LatLng>[]
      : _serpentine(origin, walkPoints, stepMeters);
  var coldMs = 0.0;
  var warmMs = <double>[];
  var matchedWays = 0;
  var matchedMeters = 0.0;
  var corridors = 0;
  if (walk.isNotEmpty) {
    final matcher = GeometricRoadMatcher(road);
    final cold = Stopwatch()..start();
    final result = matcher.match(walk);
    cold.stop();
    coldMs = cold.elapsedMicroseconds / 1000.0;
    matchedWays = result.matchedMeters.length;
    matchedMeters = result.matchedMeters.values.fold(0.0, (a, b) => a + b);
    corridors = result.corridors.values.fold(0, (a, list) => a + list.length);
    warmMs = [
      for (var i = 0; i < warmRuns; i++)
        () {
          final w = Stopwatch()..start();
          matcher.match(walk);
          w.stop();
          return w.elapsedMicroseconds / 1000.0;
        }(),
    ];
  }

  return {
    'fileBytes': fileBytes,
    'directoryBytes': road.directoryByteCount,
    'openMs': openMs,
    'buckets': keys.length,
    'payloadBytes': payloadBytes,
    'ways': wayCount,
    'scanMs': scanMs,
    'avgBucketMs': avgBucketMs,
    'maxBucketMs': maxBucketMs,
    'densestKey': denseKey,
    'densestWays': denseWays,
    'densestMs': denseMs,
    'walkPoints': walk.length,
    'walkKm': walk.length * stepMeters / 1000,
    'coldMs': coldMs,
    'warmMs': warmMs,
    'matchedWays': matchedWays,
    'matchedMeters': matchedMeters,
    'corridors': corridors,
  };
}

/// Benchmarks the region file at [path]: three timed opens (the first one
/// cold) folded into the store core, plus the walk and match measurements.
/// The store it opens is closed before returning, so calling this from an
/// [Isolate.run] closure in the app never touches the UI's own store.
Future<Map<String, Object>> runRoadBench(String path,
    {int walkPoints = 2000,
    double stepMeters = 5.0,
    LatLng? walkOrigin,
    int warmRuns = 5}) {
  final fileBytes = File(path).lengthSync();
  final openMs = <double>[];
  RoadStore? store;
  for (var i = 0; i < 3; i++) {
    final w = Stopwatch()..start();
    final s = RoadStore.open(path);
    w.stop();
    openMs.add(w.elapsedMicroseconds / 1000.0);
    store ??= s; // the cold first open carries the scan and the match
    if (!identical(s, store)) s.close();
  }
  try {
    return Future.value(benchRoadStore(store!,
        fileBytes: fileBytes,
        openMs: openMs,
        walkPoints: walkPoints,
        stepMeters: stepMeters,
        walkOrigin: walkOrigin,
        warmRuns: warmRuns));
  } finally {
    store!.close();
  }
}

/// The center of a z12 tile given its "x_y" bucket key.
LatLng _bucketCenter(String key) {
  final parts = key.split('_');
  final x = int.parse(parts[0]);
  final y = int.parse(parts[1]);
  const zoom = 12;
  final n = math.pow(2, zoom).toDouble();
  final lon = (x + 0.5) / n * 360 - 180;
  // Inverse Web Mercator for the tile's center row.
  final t = math.pi * (1 - 2 * (y + 0.5) / n);
  final lat = 2 * math.atan(math.exp(t)) - math.pi / 2;
  return LatLng(lat * 180 / math.pi, lon);
}

/// A serpentine walk starting at [center]: [points] fixed every
/// [stepMeters], running 400 m legs east/west and stepping 12 m north per
/// leg — the rhythm of a ride through street geometry.
List<LatLng> _serpentine(LatLng center, int points, double stepMeters) {
  const metersPerDegLat = 111320.0;
  final lonStep = stepMeters /
      (metersPerDegLat * math.cos(center.latitude * math.pi / 180));
  final legPoints = (400.0 / stepMeters).round();
  final rowLat = 12.0 / metersPerDegLat;
  final out = <LatLng>[];
  var lat = center.latitude;
  var lon = center.longitude;
  var dir = 1;
  for (var i = 0; i < points; i++) {
    out.add(LatLng(lat, lon));
    if (i % legPoints == legPoints - 1) {
      lat += rowLat;
      dir = -dir;
    } else {
      lon += dir * lonStep;
    }
  }
  return out;
}
