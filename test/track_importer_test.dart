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
  });
}
