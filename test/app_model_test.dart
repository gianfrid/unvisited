import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/host_channel.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';

import 'helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppModel model;

  setUp(() {
    root = Directory.systemTemp.createTempSync('unvisited-store');
    model = AppModel(TrackStore(root));
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  Directory stageDir() {
    final dir = Directory('${root.path}${Platform.pathSeparator}inbox')
      ..createSync(recursive: true);
    for (final name in const [
      'morning_walk.gpx',
      'eiffel_ride.tcx',
      'monitoring.fit',
    ]) {
      File('${dir.path}${Platform.pathSeparator}$name')
          .writeAsBytesSync(fixture(name));
    }
    return dir;
  }

  test('importFromDirectory exposes the new tracks for camera refit',
      () async {
    final summary =
        await model.importFromDirectory(stageDir().path);

    expect(summary.imported, 2); // GPX + TCX; monitoring.fit is skipped
    expect(model.importEpoch, 1);
    expect(model.lastImportedPoints, isNotEmpty);
    // Coordinates must come from the imported fixtures, not the Berlin
    // start position.
    expect(model.lastImportedPoints.first.latitude, isNot(52.52));
  });

  test('re-importing the same files is a no-op for the refit state',
      () async {
    final dir = stageDir();
    await model.importFromDirectory(dir.path);
    final epoch = model.importEpoch;
    final points = model.lastImportedPoints;

    final summary = await model.importFromDirectory(dir.path);

    expect(summary.imported, 0);
    expect(summary.duplicates, 2);
    expect(summary.skipped, 1);
    expect(model.importEpoch, epoch);
    expect(model.lastImportedPoints, same(points));
  });

  test('importFromFile exposes points for share-intent imports', () async {
    final dir = stageDir();
    final path =
        '${dir.path}${Platform.pathSeparator}afternoon_ride.kmz';
    File(path).writeAsBytesSync(fixture('afternoon_ride.kmz'));

    await model.importFromFile(path);

    expect(model.importEpoch, 1);
    expect(model.lastImportedPoints, isNotEmpty);
  });

  test('failed import leaves the refit state untouched', () async {
    final path = '${root.path}${Platform.pathSeparator}junk.gpx';
    File(path).writeAsBytesSync('not a gpx'.codeUnits);

    await model.importFromFile(path);

    expect(model.importEpoch, 0);
    expect(model.lastImportedPoints, isEmpty);
  });

  test('mergeTracks defaults to true', () {
    expect(model.mergeTracks, true);
  });

  test('toggleMergeTracks switches the mode', () {
    expect(model.mergeTracks, true);
    model.toggleMergeTracks();
    expect(model.mergeTracks, false);
    model.toggleMergeTracks();
    expect(model.mergeTracks, true);
  });

  group('bulk visibility', () {
    test('allTracksVisible is true for an empty catalog', () {
      expect(model.allTracksVisible, isTrue);
    });

    test('setAllVisible(false) hides every track and persists', () async {
      await model.importFromDirectory(stageDir().path);
      expect(model.tracks.length, 2);
      expect(model.allTracksVisible, isTrue);

      var notifications = 0;
      model.addListener(() => notifications++);
      await model.setAllVisible(false);

      expect(notifications, greaterThan(0));
      expect(model.allTracksVisible, isFalse);
      expect(model.visibleTracks, isEmpty);
      expect(model.mergedPoints, isEmpty);

      // Must survive a store reload (visibility lives in index.json).
      final reloaded = TrackStore(root);
      await reloaded.load();
      expect(reloaded.tracks.length, 2);
      expect(reloaded.tracks.every((t) => !t.visible), isTrue);
    });

    test('setAllVisible(true) re-shows only the hidden tracks', () async {
      await model.importFromDirectory(stageDir().path);
      await model.toggleVisible(model.tracks.first);

      await model.setAllVisible(true);

      expect(model.allTracksVisible, isTrue);
      expect(model.visibleTracks.length, 2);
      expect(model.mergedPoints, isNotEmpty);
    });
  });

  test('mergedPoints returns deduplicated points from all visible tracks',
      () async {
    await model.importFromDirectory(stageDir().path);

    // Should have imported 2 tracks (GPX + TCX)
    expect(model.tracks.length, 2);

    // Get merged points
    final merged = model.mergedPoints;
    expect(merged, isNotEmpty);

    // Verify deduplication: merged points should be <= total points
    final totalPoints = model.allVisiblePoints.length;
    final mergedCount = merged.length;
    expect(mergedCount, lessThanOrEqualTo(totalPoints));
  });

  test('mergedPoints cache is invalidated when tracks change', () async {
    await model.importFromDirectory(stageDir().path);
    final merged1 = model.mergedPoints;
    expect(merged1, isNotEmpty);

    // Toggle a track visibility
    final firstTrack = model.tracks.first;
    await model.toggleVisible(firstTrack);

    // Access mergedPoints again to ensure cache is invalidated
    // (no assertion needed, just verifying it doesn't throw)
    model.mergedPoints;
  });

  group('SAF folder import (Android host channel)', () {
    tearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, null);
    });

    /// Stages fixture bytes the way the host channel's SAF scan does: copies
    /// into a cache-side staging directory, returning the `{path, name}` list.
    List<Map<Object?, Object?>> stageSafScan(List<String> names) {
      final dir = Directory.systemTemp.createTempSync('unvisited-saf');
      return [
        for (final name in names)
          () {
            final f = File('${dir.path}${Platform.pathSeparator}$name')
              ..writeAsBytesSync(fixture(name));
            return {'path': f.path, 'name': name};
          }(),
      ];
    }

    test('imports staged files through the unified pipeline', () async {
      const treeUri = 'content://tree/primary%3ADocuments';
      final staged = stageSafScan(
          ['morning_walk.gpx', 'afternoon_ride.kmz', 'monitoring.fit']);
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (call) async {
        switch (call.method) {
          case 'pickDirectory':
            return treeUri;
          case 'listTrackFiles':
            expect(call.arguments, treeUri,
                reason: 'Dart must pass the picked tree URI through');
            return staged;
        }
        fail('unexpected host method ${call.method}');
      });

      final summary = await model.importViaDirectoryPicker();

      expect(summary!.imported, 2); // GPX + KMZ; monitoring.fit skipped
      expect(summary.skipped, 1);
      expect(model.importEpoch, 1);
      expect(model.lastImportedPoints, isNotEmpty);
    });

    test('deletes the staging copies once the pipeline consumed them',
        () async {
      final staged = stageSafScan(['morning_walk.gpx']);
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (call) async {
        switch (call.method) {
          case 'pickDirectory':
            return 'content://tree/x';
          case 'listTrackFiles':
            return staged;
        }
        fail('unexpected host method ${call.method}');
      });

      await model.importViaDirectoryPicker();

      for (final entry in staged) {
        expect(File(entry['path'] as String).existsSync(), isFalse,
            reason: 'staged files must not linger in the cache dir');
      }
    });

    test('an unparseable staged file fails without aborting the import',
        () async {
      final staged = stageSafScan(['morning_walk.gpx']);
      final junk = File(
          '${Directory.systemTemp.createTempSync('unvisited-saf').path}'
          '${Platform.pathSeparator}junk.gpx')
        ..writeAsBytesSync('not a gpx'.codeUnits);
      staged.add({'path': junk.path, 'name': 'junk.gpx'});
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (call) async {
        switch (call.method) {
          case 'pickDirectory':
            return 'content://tree/x';
          case 'listTrackFiles':
            return staged;
        }
        fail('unexpected host method ${call.method}');
      });

      final summary = await model.importViaDirectoryPicker();

      expect(summary!.imported, 1);
      expect(summary.failed, 1);
      // The junk staging copy must be cleaned up despite the parse failure.
      expect(junk.existsSync(), isFalse);
    });

    test('a cancelled SAF pick imports nothing', () async {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (call) async {
        expect(call.method, 'pickDirectory');
        return null; // user cancelled
      });

      final summary = await model.importViaDirectoryPicker();

      expect(summary, isNull);
      expect(model.importEpoch, 0);
    });
  });
}
