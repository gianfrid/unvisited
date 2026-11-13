import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/road/road_store.dart';

import '../tool/build_roads.dart' show buildRoadFile;
import '../tool/pbf_reader.dart';
import 'helpers.dart';

void main() {
  group('looksLikeOsmPbf', () {
    test('accepts a PBF by content, no matter the filename', () {
      expect(looksLikeOsmPbf(fixture('town.osm.pbf')), isTrue);
    });

    test('rejects other formats (the sniff is content-based, like the '
        'track import)', () {
      expect(looksLikeOsmPbf(fixture('main_street_walk.gpx')), isFalse);
      expect(looksLikeOsmPbf(fixture('test_roads_source.json')), isFalse);
      expect(looksLikeOsmPbf(fixture('activity_ride.fit')), isFalse);
    });

    test('short input is not a PBF', () {
      expect(looksLikeOsmPbf(const [0x0A]), isFalse);
      expect(looksLikeOsmPbf(const []), isFalse);
    });
  });

  group('extractHighwayWays', () {
    late PbfExtraction extraction;
    setUpAll(() {
      extraction = extractHighwayWays('test/fixtures/town.osm.pbf');
    });

    test('keeps highway ways, resolves tags, drops the rest', () {
      expect(extraction.totalWays, 4);
      expect(extraction.highwayWays, 3);
      // Way 103 (footway) references a node that is not in the file, so
      // only two ways come out with usable geometry.
      expect(extraction.ways.length, 2);
      expect(extraction.missingNodeWays, 1);
      final byId = {for (final w in extraction.ways) w['id'] as String: w};
      final weinbergs = byId['100']!;
      expect(weinbergs['class'], 'service');
      expect(weinbergs['name'], 'Weinbergsweg');
      final torstrasse = byId['101']!;
      expect(torstrasse['class'], 'primary');
      expect(torstrasse['name'], 'Torstraße');
    });

    test('decodes coordinates through granularity and offsets', () {
      final byId = {for (final w in extraction.ways) w['id'] as String: w};
      final points = (byId['100']!['points'] as List).cast<List<double>>();
      expect(points.length, 3);
      // Plain-node block: granularity 100, no offsets.
      expect(points[0][0], closeTo(52.5280, 1e-9));
      expect(points[0][1], closeTo(13.4020, 1e-9));
      // Third node lives in the *dense* block with granularity 1000 and
      // non-zero lat/lon offsets — the reader's block-scoped scalars.
      expect(points[2][0], closeTo(52.5250, 1e-9));
      expect(points[2][1], closeTo(13.4000, 1e-9));
      // Way 101 reaches back into block A for its first node, so geometry
      // resolves across blobs.
      final torPoints = (byId['101']!['points'] as List).cast<List<double>>();
      expect(torPoints.length, 3);
      expect(torPoints[0][0], closeTo(52.5250, 1e-9));
      expect(torPoints[2][0], closeTo(52.5260, 1e-9));
    });

    test('the building way (no highway tag) is filtered out', () {
      final ids = extraction.ways.map((w) => w['id']).toList();
      expect(ids, isNot(contains('102')));
    });

    test('tolerates a truncated file, reporting what it skipped', () {
      final dir = Directory.systemTemp.createTempSync('unvisited_pbf_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = fixture('town.osm.pbf');
      // Cut inside the last frame (the zlib block): block A survives.
      final path = '${dir.path}/cut.osm.pbf';
      File(path).writeAsBytesSync(bytes.sublist(0, bytes.length - 10));
      final warnings = <String>[];
      final extraction = extractHighwayWays(path, onWarning: warnings.add);
      expect(extraction.truncatedBlobs, 1);
      expect(warnings, isNotEmpty);
      // Way 100's nodes all live in the surviving block A, so it comes out
      // intact; way 101 reaches into the lost block and is reported as a
      // missing-node drop — the honest answer for a cut file.
      expect(extraction.ways.length, 1);
      expect(extraction.ways.single['id'], '100');
      expect(extraction.missingNodeWays, 1);
    });
  });

  group('end to end: PBF to road file', () {
    late Directory tmp;
    late String roadPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('unvisited_pbf_test');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('the extracted ways build a road file the store opens', () {
      final extraction = extractHighwayWays('test/fixtures/town.osm.pbf');
      roadPath = '${tmp.path}/town.unvisited-roads';
      buildRoadFile(extraction.ways, roadPath);

      final store = RoadStore.open(roadPath);
      addTearDown(store.close);
      final bucket = store.bucketAt(52.5280, 13.4020);
      final weinbergs = bucket.where((w) => w.id == '100').single;
      expect(weinbergs.highwayClass, 'service');
      expect(weinbergs.name, 'Weinbergsweg');
      expect(weinbergs.points.first.latitude, closeTo(52.5280, 1e-9));
      expect(weinbergs.points.first.longitude, closeTo(13.4020, 1e-9));
    });
  });
}
