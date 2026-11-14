// ignore_for_file: avoid_print
// Benchmark harness for the road pipeline: file parse, geometry decode and
// geometric matching against a synthetic city grid.
//
// Run with: dart run tool/bench_roads.dart [--blocks N] [--points N]
//                                          [--step M] [--iterations N]
//         or: dart run tool/bench_roads.dart --roads <region.roads>
// The --roads form benchmarks a real region file (same measurements as the
// app's profile-mode run) instead of the synthetic city below.
//
// The synthetic city is a grid: `blocks`×`blocks` city blocks of 100 m,
// every street segment between intersections its own way (OSM-like), points
// every 25 m. Defaults (100) produce ~20k ways / ~100k segments — roughly a
// mid-sized city's road network. The synthetic walk is a serpentine along
// the grid's streets with a point every `step` meters (5 m ≈ a 3.6 s GPS
// interval at walking speed), `points` in total.
//
// Purpose: baseline numbers for the pure-Dart matcher, so the "Rust core?"
// decision (TODO slice 7 / report finding 5) is made on measurement, and
// later, A/B numbers for the Rust implementation behind the same interface.

import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:unvisited/road/road_bench.dart';
import 'package:unvisited/road/road_matcher.dart';
import 'package:unvisited/road/road_store.dart';

import 'build_roads.dart' show buildRoadFile;

const blockMeters = 100.0;
const wayPointEveryMeters = 25.0;
const metersPerDegLat = 111320.0;

Future<void> main(List<String> args) async {
  var blocks = 100;
  var trackPoints = 10000;
  var stepMeters = 5.0;
  var iterations = 5;
  String? roadsPath;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--roads':
        roadsPath = args[++i];
      case '--blocks':
        blocks = int.parse(args[++i]);
      case '--points':
        trackPoints = int.parse(args[++i]);
      case '--step':
        stepMeters = double.parse(args[++i]);
      case '--iterations':
        iterations = int.parse(args[++i]);
      default:
        print('unknown arg ${args[i]}');
        exit(2);
    }
  }

  // Real-region mode: the same measurements the profile-mode in-app run
  // prints (lib/road/road_bench.dart), for the desktop column of the A/B.
  if (roadsPath != null) {
    print('real region: $roadsPath');
    print(benchReport(await runRoadBench(roadsPath)));
    return;
  }

  final lat0 = 52.5200;
  final lon0 = 13.4050;
  final dLat = blockMeters / metersPerDegLat;
  final dLon = blockMeters /
      (metersPerDegLat * math.cos(lat0 * math.pi / 180));

  LatLng at(int row, int col) =>
      LatLng(lat0 + row * dLat, lon0 + col * dLon);

  // The grid: every street segment between intersections is one way, with
  // geometry points every 25 m.
  final ways = <Map<String, dynamic>>[];
  var wayId = 1000;
  List<LatLng> polyline(LatLng a, LatLng b) {
    final len = const Distance().distance(a, b);
    final n = (len / wayPointEveryMeters).ceil();
    return [
      for (var i = 0; i <= n; i++)
        LatLng(
          a.latitude + (b.latitude - a.latitude) * i / n,
          a.longitude + (b.longitude - a.longitude) * i / n,
        ),
    ];
  }

  for (var row = 0; row <= blocks; row++) {
    for (var col = 0; col < blocks; col++) {
      ways.add({
        'id': '${wayId++}',
        'class': 'residential',
        'name': 'Street $wayId',
        'points': polyline(at(row, col), at(row, col + 1))
            .map((p) => [p.latitude, p.longitude])
            .toList(),
      });
      ways.add({
        'id': '${wayId++}',
        'class': 'residential',
        'name': 'Street $wayId',
        'points': polyline(at(col, row), at(col + 1, row))
            .map((p) => [p.latitude, p.longitude])
            .toList(),
      });
    }
  }
  print('synthetic city: ${ways.length} ways, '
      '${ways.length * (blockMeters / wayPointEveryMeters).round()} segments, '
      '${(blocks * blockMeters / 1000).toStringAsFixed(1)} km grid');

  final tmp = Directory.systemTemp.createTempSync('unvisited-bench');
  try {
    // Build the road file in-process (the writer is a library function).
    final roadPath = '${tmp.path}/bench.roads';
    final buildWatch = Stopwatch()..start();
    buildRoadFile(ways, roadPath);
    buildWatch.stop();
    final roadFile = File(roadPath);
    print('road file: ${_mb(roadFile.lengthSync())} MB '
        '(build ${buildWatch.elapsedMilliseconds} ms)');

    // 1. Parse/open.
    final parseTimes = <double>[];
    RoadStore? store;
    for (var i = 0; i < 3; i++) {
      final w = Stopwatch()..start();
      store = RoadStore.open(roadPath);
      w.stop();
      parseTimes.add(w.elapsedMicroseconds / 1000);
    }
    print('open (parse + index): '
        '${parseTimes.map((t) => t.toStringAsFixed(1)).join(' / ')} ms');

    // 2. A serpentine walk along the grid's streets, `trackPoints` points
    //    every `stepMeters`.
    final walk = <LatLng>[];
    var row = 0;
    var col = 0.0;
    var going = 1; // east first
    for (var i = 0; i < trackPoints; i++) {
      walk.add(LatLng(lat0 + row * dLat, lon0 + col * dLon));
      col += going * stepMeters / blockMeters;
      if (col >= blocks || col <= 0) {
        col = col.clamp(0.0, blocks.toDouble());
        row++;
        going = -going;
        if (row > blocks) row = 0; // wrap: keep walking forever
      }
    }
    print('walk: ${walk.length} points, '
        '${(walk.length * stepMeters / 1000).toStringAsFixed(1)} km');

    // 3. Match: one cold run (builds the segment index, decodes every
    //    geometry), then warm iterations.
    final matcher = GeometricRoadMatcher(store!);
    final indexWatch = Stopwatch()..start();
    matcher.ensureIndex();
    indexWatch.stop();
    print('segment index build: ${indexWatch.elapsedMilliseconds} ms');

    final cold = Stopwatch()..start();
    final coldResult = matcher.match(walk);
    cold.stop();
    print('match cold: ${cold.elapsedMilliseconds} ms '
        '(${coldResult.matchedMeters.length} ways touched, '
        'corridors ${coldResult.corridors.length})');

    final warmTimes = <int>[];
    for (var i = 0; i < iterations; i++) {
      final w = Stopwatch()..start();
      matcher.match(walk);
      w.stop();
      warmTimes.add(w.elapsedMilliseconds);
    }
    final avg =
        warmTimes.reduce((a, b) => a + b) / warmTimes.length;
    final min = warmTimes.reduce(math.min);
    print('match warm: avg ${avg.toStringAsFixed(1)} ms / '
        'min $min ms over $iterations runs');

    // 4. Per-import budget check: matching is part of the import path; an
    //    import of this track should stay interactive (< 1 s total).
    final budget = cold.elapsedMilliseconds + parseTimes.first;
    print('import-path budget (open + one match): $budget ms '
        '${budget < 1000 ? '✓ interactive' : '✗ over the 1 s bar'}');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(2);
