import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/import/track_importer.dart';
import 'package:unvisited/storage/track_store.dart';

import 'helpers.dart';

void main() {
  final importer = TrackImporter();

  group('TrackImporter format detection (priority GPX > FIT > KMZ > TCX > KML)',
      () {
    test('knows each fixture format', () {
      expect(importer.detect(fixture('morning_walk.gpx'))?.format, 'GPX');
      expect(importer.detect(fixture('activity_ride.fit'))?.format, 'FIT');
      expect(importer.detect(fixture('afternoon_ride.kmz'))?.format, 'KMZ');
      expect(importer.detect(fixture('eiffel_ride.tcx'))?.format, 'TCX');
      expect(importer.detect(fixture('afternoon_ride.kml'))?.format, 'KML');
    });

    test('content wins over misleading file extensions', () {
      // FIT bytes arriving as .gpx (the classic share-intent mangling)
      final fitBytes = fixture('activity_ride.fit');
      final data = importer.import(fitBytes, filename: 'export.gpx');
      expect(data.format, 'FIT');
      // KML bytes arriving as .gpx
      final kmlBytes = fixture('afternoon_ride.kml');
      final kml = importer.import(kmlBytes, filename: 'export.gpx');
      expect(kml.format, 'KML');
    });

    test('monitoring FIT files surface as skipped', () {
      expect(
        () => importer.import(fixture('monitoring.fit')),
        throwsA(isA<UnsupportedTrackException>()),
      );
    });

    test('unknown bytes fail as TrackParseException, not a crash', () {
      expect(
        () => importer.import(List.filled(33, 7)),
        throwsA(isA<TrackParseException>()),
      );
    });

    test('truncated FIT still imports with partial points', () {
      final data = importer.import(fixture('truncated_ride.fit'),
          filename: 'truncated_ride.fit');
      expect(data.points, isNotEmpty);
      expect(data.points.length, greaterThanOrEqualTo(3));
    });
  });

  group('contentHash (dedup key basics)', () {
    test('stable and content-sensitive', () {
      final a = contentHash(fixture('morning_walk.gpx'));
      expect(a, contentHash(fixture('morning_walk.gpx')));
      expect(a, isNot(contentHash(fixture('eiffel_ride.tcx'))));
      expect(a.length, 16);
    });
  });

  group('full TrackStore round trip', () {
    late TrackStore store;
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('unvisited_test');
      store = TrackStore(tmp);
      await store.load();
    });

    tearDown(() async {
      tmp.deleteSync(recursive: true);
    });

    test('import → persisted file + index entry', () async {
      final r = store.importBytes(fixture('morning_walk.gpx'),
          filename: 'morning_walk.gpx');
      expect(r.imported, isTrue);
      expect(r.track!.format, 'GPX');
      expect(r.track!.pointCount, 5);
      expect(Directory('${tmp.path}/tracks').existsSync(), isTrue);
      expect(File('${tmp.path}/index.json').existsSync(), isTrue);
    });

    test('plain KML imports through the store (regression: the wired parser '
        'list used to omit KmlParser)', () async {
      // The store's own importer — not the TrackImporter default — is what
      // the app runs, so detect through it.
      expect(store.importer.detect(fixture('afternoon_ride.kml'))?.format,
          'KML');
      final r = store.importBytes(fixture('afternoon_ride.kml'),
          filename: 'afternoon_ride.kml');
      expect(r.imported, isTrue);
      expect(r.track!.format, 'KML');
      expect(r.track!.name, 'Afternoon ride');
      expect(r.track!.pointCount, 3);
      expect(store.tracks.length, 1);
    });

    test('re-import of identical bytes is a dedup no-op', () {
      final first = store.importBytes(fixture('activity_ride.fit'),
          filename: 'activity_ride.fit');
      final second = store.importBytes(fixture('activity_ride.fit'),
          filename: 'another_name.fit');
      expect(first.imported, isTrue);
      expect(second.imported, isFalse);
      expect(second.outcome, isA<ImportDuplicate>());
      expect(store.tracks.length, 1);
    });

    test('the same activity re-exported in another format is a duplicate',
        () {
      // activity_ride.gpx holds the same coordinates and timestamps as
      // activity_ride.fit under different bytes and a different name.
      final first = store.importBytes(fixture('activity_ride.fit'),
          filename: 'activity_ride.fit');
      final second = store.importBytes(fixture('activity_ride.gpx'),
          filename: 'activity_ride.gpx');
      expect(first.imported, isTrue);
      expect(second.imported, isFalse);
      expect(second.outcome, isA<ImportDuplicate>());
      expect(store.tracks.length, 1);
      // The stored copy is the first import; the near-duplicate is not
      // written to disk.
      expect(File('${tmp.path}/tracks/${first.track!.id}.gpx').existsSync(),
          isFalse);
    });

    test('two activities sharing a start time are both kept', () {
      // eiffel_ride.tcx starts at the same second as activity_ride.fit
      // but is a short stroll, not a 700 m ride: start time alone must
      // not dedup.
      final fit = store.importBytes(fixture('activity_ride.fit'),
          filename: 'activity_ride.fit');
      final tcx = store.importBytes(fixture('eiffel_ride.tcx'),
          filename: 'eiffel_ride.tcx');
      expect(fit.imported, isTrue);
      expect(tcx.imported, isTrue);
      expect(store.tracks.length, 2);
    });

    test('an activity without a start time is never near-deduped', () {
      // A track whose points carry no timestamps (start unknown) must
      // fall back to the byte-hash rule only.
      const timeless = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
          '<trk><name>Timeless</name><trkseg>'
          '<trkpt lat="52.52000" lon="13.40500"/>'
          '<trkpt lat="52.52100" lon="13.40600"/>'
          '</trkseg></trk></gpx>';
      final first = store.importBytes(timeless.codeUnits,
          filename: 'timeless.gpx');
      expect(first.imported, isTrue);
      // A same-shaped track with the same (absent) start does not dedup
      // against it: without a start time the heuristic stays silent.
      const timeless2 = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
          '<trk><name>Timeless too</name><trkseg>'
          '<trkpt lat="52.52000" lon="13.40500"/>'
          '<trkpt lat="52.52100" lon="13.40600"/>'
          '</trkseg></trk></gpx>';
      final second = store.importBytes(timeless2.codeUnits,
          filename: 'timeless2.gpx');
      expect(second.imported, isTrue);
      expect(store.tracks.length, 2);
      // Identical bytes still dedup through the content hash.
      final third = store.importBytes(timeless.codeUnits,
          filename: 'timeless-again.gpx');
      expect(third.imported, isFalse);
      expect(third.outcome, isA<ImportDuplicate>());
    });

    test('monitoring files are skipped with a reason', () {
      final r = store.importBytes(fixture('monitoring.fit'),
          filename: 'monitoring.fit');
      expect(r.imported, isFalse);
      switch (r.outcome) {
        case ImportSkipped(:final reason):
          expect(reason, contains('monitoring'));
        default:
          fail('expected ImportSkipped, got ${r.outcome}');
      }
      expect(store.tracks, isEmpty);
    });

    test('bytes of no known format report ImportFailed', () {
      final r = store.importBytes('not a track'.codeUnits,
          filename: 'junk.bin');
      expect(r.imported, isFalse);
      expect(r.outcome, isA<ImportFailed>());
      expect(store.tracks, isEmpty);
    });

    test('load() restores the catalog across restarts', () async {
      store.importBytes(fixture('activity_ride.fit'), filename: 'ride.fit');
      store.importBytes(fixture('morning_walk.gpx'), filename: 'walk.gpx');
      final reopened = TrackStore(tmp);
      await reopened.load();
      expect(reopened.tracks.length, 2);
      expect(reopened.tracks.map((t) => t.format), containsAll(['FIT', 'GPX']));
      // points round-trip through the stored file
      final pts = reopened.loadPoints(reopened.tracks.first);
      expect(pts, isNotNull);
      expect(pts!.points, isNotEmpty);
    });

    test('remove() deletes file and index entry', () async {
      final r = store.importBytes(fixture('morning_walk.gpx'),
          filename: 'morning_walk.gpx');
      await store.remove(r.track!);
      expect(store.tracks, isEmpty);
      expect(File('${tmp.path}/tracks/${r.track!.file}').existsSync(), isFalse);
      final reopened = TrackStore(tmp);
      await reopened.load();
      expect(reopened.tracks, isEmpty);
    });

    test('visibility toggles persist', () async {
      final r = store.importBytes(fixture('morning_walk.gpx'),
          filename: 'morning_walk.gpx');
      await store.setVisible(r.track!, false);
      final reopened = TrackStore(tmp);
      await reopened.load();
      expect(reopened.tracks.first.visible, isFalse);
    });

    test('duration of the point timestamps persists and round-trips', () async {
      final r = store.importBytes(fixture('morning_walk.gpx'),
          filename: 'morning_walk.gpx');
      // 07:05:00 → 07:09:00.
      expect(r.track!.durationSeconds, 240);
      final reopened = TrackStore(tmp);
      await reopened.load();
      expect(reopened.tracks.first.durationSeconds, 240);
    });

    test('a recorded track carries its staging-GPX duration', () {
      // The stage writer emits <time> per point; the import pipeline
      // turns it into a duration like any GPX.
      final r = store.importBytes(fixture('recorded_ride.gpx'),
          filename: 'recorded_ride.gpx');
      expect(r.imported, isTrue);
      // 18:00:00.000 → 18:00:08.000.
      expect(r.track!.durationSeconds, 8);
    });

    test('an index written before durationSeconds still loads', () async {
      store.importBytes(fixture('morning_walk.gpx'),
          filename: 'morning_walk.gpx');
      // Simulate an old index: strip the field the old writer never had.
      final f = File('${tmp.path}/index.json');
      final entries = (jsonDecode(f.readAsStringSync())
          as Map<String, dynamic>)['tracks'] as List;
      for (final m in entries) {
        (m as Map).remove('durationSeconds');
      }
      f.writeAsStringSync(jsonEncode({'tracks': entries}));
      final reopened = TrackStore(tmp);
      await reopened.load();
      expect(reopened.tracks.first.durationSeconds, isNull);
      expect(reopened.tracks.first.distanceMeters, greaterThan(0));
    });

    // The self-heal of the two tests below: opening a track fills a
    // legacy entry's missing timeline fields from the parsed file and
    // persists them (docs/plans/2026-11-19-catalog-timeline-backfill.md).

    test('opening a track heals a legacy entry, and it persists', () async {
      store.importBytes(fixture('morning_walk.gpx'),
          filename: 'morning_walk.gpx');
      // Simulate an old index: strip both timeline fields.
      final f = File('${tmp.path}/index.json');
      final entries = (jsonDecode(f.readAsStringSync())
          as Map<String, dynamic>)['tracks'] as List;
      for (final m in entries) {
        (m as Map)
          ..remove('durationSeconds')
          ..remove('startTimeUtc');
      }
      f.writeAsStringSync(jsonEncode({'tracks': entries}));
      final reopened = TrackStore(tmp);
      await reopened.load();
      final track = reopened.tracks.first;
      expect(track.durationSeconds, isNull);
      expect(track.startTimeUtc, isNull);

      // One open heals: the morning walk spans 07:05:00 → 07:09:00.
      final data = reopened.loadPoints(track);
      expect(data, isNotNull);
      expect(track.durationSeconds, 240);
      expect(track.startTimeUtc, isNotNull);
      // Healed is persisted: a restart keeps the timeline.
      final healed = TrackStore(tmp);
      await healed.load();
      expect(healed.tracks.first.durationSeconds, 240);
      expect(healed.tracks.first.startTimeUtc, isNotNull);
    });

    test('the heal never overwrites a set value, nor invents one', () async {
      store.importBytes(fixture('morning_walk.gpx'),
          filename: 'morning_walk.gpx');
      // A wrong-but-set value stays: the index is the record of what was
      // true at import, the heal only fills what is missing.
      final f = File('${tmp.path}/index.json');
      final entries = (jsonDecode(f.readAsStringSync())
          as Map<String, dynamic>)['tracks'] as List;
      (entries.first as Map)['durationSeconds'] = 999;
      f.writeAsStringSync(jsonEncode({'tracks': entries}));
      final reopened = TrackStore(tmp);
      await reopened.load();
      reopened.loadPoints(reopened.tracks.first);
      expect(reopened.tracks.first.durationSeconds, 999);

      // A timeline-less track keeps null: no fabricated duration.
      final bare = store.importBytes(
          '<?xml version="1.0"?><gpx version="1.1"><trk><name>bare</name>'
              '<trkseg><trkpt lat="45" lon="9"/><trkpt lat="45.001" lon="9"/>'
              '</trkseg></trk></gpx>'
              .codeUnits,
          filename: 'bare.gpx');
      expect(bare.track!.durationSeconds, isNull);
      store.loadPoints(bare.track!);
      expect(bare.track!.durationSeconds, isNull);
    });
  });
}
