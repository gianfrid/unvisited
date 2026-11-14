import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/import/track_importer.dart';
import 'package:unvisited/storage/track_store.dart';

import 'helpers.dart';

void main() {
  final importer = TrackImporter();

  group('TrackImporter format detection (priority GPX > FIT > KMZ > TCX)', () {
    test('knows each fixture format', () {
      expect(importer.detect(fixture('morning_walk.gpx'))?.format, 'GPX');
      expect(importer.detect(fixture('activity_ride.fit'))?.format, 'FIT');
      expect(importer.detect(fixture('afternoon_ride.kmz'))?.format, 'KMZ');
      expect(importer.detect(fixture('eiffel_ride.tcx'))?.format, 'TCX');
    });

    test('content wins over misleading file extensions', () {
      // FIT bytes arriving as .gpx (the classic share-intent mangling)
      final fitBytes = fixture('activity_ride.fit');
      final data = importer.import(fitBytes, filename: 'export.gpx');
      expect(data.format, 'FIT');
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

    test('re-import of identical bytes is a dedup no-op', () {
      final first = store.importBytes(fixture('activity_ride.fit'),
          filename: 'activity_ride.fit');
      final second = store.importBytes(fixture('activity_ride.fit'),
          filename: 'another_name.fit');
      expect(first.imported, isTrue);
      expect(second.imported, isFalse);
      expect(second.reason, 'duplicate');
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
      expect(second.reason, 'duplicate');
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
      expect(third.reason, 'duplicate');
    });

    test('monitoring files are skipped with a reason', () {
      final r = store.importBytes(fixture('monitoring.fit'),
          filename: 'monitoring.fit');
      expect(r.imported, isFalse);
      expect(r.reason, contains('monitoring'));
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
  });
}
