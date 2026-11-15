import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/import_coordinator.dart';

import 'helpers.dart';

void main() {
  late Directory root;
  late TrackStore store;
  late ImportCoordinator coordinator;
  late int changes;

  setUp(() {
    root = createRoot();
    store = TrackStore(root);
    changes = 0;
    coordinator = ImportCoordinator(
      store: store,
      roadMatcher: () => null, // no region file: circles-only
      onChanged: () => changes++,
    );
  });

  /// A folder staging the mixed-content fixtures: two importable formats
  /// and one FIT monitoring file that must be skipped, plus one file that
  /// parses as nothing (the .gpx name passes the walk's extension filter,
  /// the content fails the sniffing).
  Directory stageDir([List<(String, List<int>)> files = const []]) {
    final dir = Directory('${root.path}${Platform.pathSeparator}inbox')
      ..createSync(recursive: true);
    for (final (name, bytes) in files) {
      File('${dir.path}${Platform.pathSeparator}$name').writeAsBytesSync(bytes);
    }
    return dir;
  }

  group('ImportSummary counters', () {
    test(
      'a mixed folder counts imported, skipped and failed separately',
      () async {
        final summary = await coordinator.importFromDirectory(
          stageDir([
            ('morning_walk.gpx', fixture('morning_walk.gpx')),
            ('eiffel_ride.tcx', fixture('eiffel_ride.tcx')),
            ('monitoring.fit', fixture('monitoring.fit')),
            ('junk.gpx', 'not a track'.codeUnits),
          ]).path,
        );

        expect(summary.imported, 2);
        expect(summary.skipped, 1);
        expect(summary.failed, 1);
        expect(summary.duplicates, 0);
        expect(summary.isEmpty, isFalse);
        expect(store.tracks, hasLength(2));
      },
    );

    test('a byte-identical re-import counts as a duplicate', () async {
      final dir = stageDir([
        ('activity_ride.fit', fixture('activity_ride.fit')),
      ]);
      await coordinator.importFromDirectory(dir.path);
      final summary = await coordinator.importFromDirectory(dir.path);

      expect(summary.imported, 0);
      expect(summary.duplicates, 1);
      expect(store.tracks, hasLength(1));
    });

    test('a fresh summary is empty', () {
      expect(ImportSummary().isEmpty, isTrue);
    });
  });

  group('epoch and refit points', () {
    test('a new import bumps the epoch and records the refit points', () async {
      final dir = stageDir([('morning_walk.gpx', fixture('morning_walk.gpx'))]);
      final before = coordinator.importEpoch;

      await coordinator.importFromDirectory(dir.path);

      expect(coordinator.importEpoch, before + 1);
      expect(coordinator.lastImportedPoints, isNotEmpty);
    });

    test('a pure duplicate import does not bump the epoch', () async {
      final dir = stageDir([
        ('activity_ride.fit', fixture('activity_ride.fit')),
      ]);
      await coordinator.importFromDirectory(dir.path);
      final epoch = coordinator.importEpoch;

      await coordinator.importFromDirectory(dir.path);

      expect(coordinator.importEpoch, epoch);
    });
  });

  group('point cache', () {
    test(
      'a directory bulk import starts the overlay from a clean cache',
      () async {
        // A stale entry for a track that is not even in this catalog.
        coordinator.rememberPoints(
          StoredTrack(
            id: 'stale',
            name: 'stale',
            format: 'GPX',
            file: 'stale.gpx',
            pointCount: 0,
            distanceMeters: 0,
          ),
          const [LatLng(52.52, 13.405)],
        );

        final dir = stageDir([
          ('morning_walk.gpx', fixture('morning_walk.gpx')),
        ]);
        await coordinator.importFromDirectory(dir.path);

        expect(store.tracks, hasLength(1));
        // The walk clears the cache: after a bulk change the overlay
        // re-reads everything from the store.
        expect(coordinator.cachedPoints(store.tracks.first), isNull);
      },
    );

    test('remember, invalidate and clear behave per track', () async {
      final track = StoredTrack(
        id: 't1',
        name: 't1',
        format: 'GPX',
        file: 't1.gpx',
        pointCount: 0,
        distanceMeters: 0,
      );

      coordinator.rememberPoints(track, const [LatLng(52.52, 13.405)]);
      expect(coordinator.cachedPoints(track), isNotNull);

      coordinator.invalidateCache(track.id);
      expect(coordinator.cachedPoints(track), isNull);

      coordinator
        ..rememberPoints(track, const [LatLng(52.52, 13.405)])
        ..clearCache();
      expect(coordinator.cachedPoints(track), isNull);
    });

    test('importFromFile runs a single file through the pipeline', () async {
      final dir = stageDir();
      final file = File('${dir.path}${Platform.pathSeparator}eiffel_ride.tcx')
        ..writeAsBytesSync(fixture('eiffel_ride.tcx'));
      final epochBefore = coordinator.importEpoch;

      await coordinator.importFromFile(file.path);

      expect(store.tracks, hasLength(1));
      expect(coordinator.importEpoch, epochBefore + 1);
      expect(coordinator.lastImportedPoints, isNotEmpty);
    });
  });

  group('notifications', () {
    test('an import notifies the owning model', () async {
      final dir = stageDir([('morning_walk.gpx', fixture('morning_walk.gpx'))]);
      await coordinator.importFromDirectory(dir.path);
      expect(changes, greaterThan(0));
    });
  });

  group('importRecordingBytes (recording finalize/salvage path)', () {
    test('imports the bytes and invalidates the cache', () {
      const gpx =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
          '<trk><name>Staged ride</name><trkseg>'
          '<trkpt lat="52.5200" lon="13.4050">'
          '<time>2026-01-01T10:00:00Z</time></trkpt>'
          '</trkseg></trk></gpx>';

      final result = coordinator.importRecordingBytes(
        gpx.codeUnits,
        'staged.gpx',
      );

      expect(result.imported, isTrue);
      expect(result.track!.name, 'Staged ride');
      expect(store.tracks.single.name, 'Staged ride');
      expect(coordinator.cachedPoints(result.track!), isNull);
      expect(changes, greaterThan(0));
    });
  });
}
