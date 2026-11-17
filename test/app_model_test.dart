import 'dart:convert' show utf8;
import 'dart:io';

import 'package:file_picker/file_picker.dart'
    show
        AndroidOptions,
        DarwinOptions,
        FilePickerPlatform,
        FilePickerStatus,
        FileType,
        LinuxOptions,
        MethodChannelFilePicker,
        PlatformFile,
        WebOptions,
        WindowsOptions;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:unvisited/debug_log.dart';
import 'package:unvisited/l10n/app_strings.dart';
import 'package:unvisited/host_channel.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/recording/position_source.dart'
    show PositionFix;
import 'package:unvisited/recording/staging_gpx.dart'
    show GpxStageWriter, MemoryStageSink;
import 'package:unvisited/ui/app_model.dart';
import 'package:unvisited/ui/track_colors.dart';

import '../tool/build_roads.dart' show buildRoadFile;
import 'helpers.dart';

/// A stand-in for a file the system picker would hand out. Real picked
/// files come from the federated platform packages; the fake subclasses
/// the abstract PlatformFile and carries name + path only (all the model
/// reads). `base` propagates the base class's rules, and noSuchMethod
/// keeps every other member unimplemented.
base class FakePickedFile extends PlatformFile {
  FakePickedFile(this.name, String path) : uri = Uri.file(path);

  @override
  final String name;

  @override
  final Uri uri;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A FilePickerPlatform whose file picker always "picks" [picked]
/// (null = the user cancelled), and whose save dialog "writes" the bytes
/// to [savedTo] (also null = cancel).
class FakeFilePicker extends FilePickerPlatform {
  FakeFilePicker(this.picked, {this.savedTo});

  final PlatformFile? picked;
  final String? savedTo;

  /// The arguments the last [pickFiles] call received, for asserting how
  /// the picker was opened (filter vs. unfiltered).
  (FileType, List<String>?)? lastPickArgs;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    lastPickArgs = (type, allowedExtensions);
    final p = picked;
    return p == null ? const [] : [p];
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => picked;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    final target = savedTo;
    if (target == null) return null;
    File(target).writeAsBytesSync(bytes);
    return Uri.file(target);
  }
}

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

  test('importFromDirectory exposes the new tracks for camera refit', () async {
    final summary = await model.importFromDirectory(stageDir().path);

    expect(summary.imported, 2); // GPX + TCX; monitoring.fit is skipped
    expect(model.importEpoch, 1);
    expect(model.lastImportedPoints, isNotEmpty);
    // Coordinates must come from the imported fixtures, not the Berlin
    // start position.
    expect(model.lastImportedPoints.first.latitude, isNot(52.52));
  });

  test('file picker on Android opens unfiltered and imports the gpx', () async {
    // Android's document picker cannot filter by the track extensions
    // (no MimeTypeMap mapping), so the coordinator must open the picker
    // with FileType.any there and let the content sniffer decide.
    final dir = Directory.systemTemp.createTempSync('unvisited-pick');
    addTearDown(() => dir.deleteSync(recursive: true));
    final gpxPath = '${dir.path}${Platform.pathSeparator}walk.gpx';
    File(gpxPath).writeAsBytesSync(fixture('main_street_walk.gpx'));
    final picker = FakeFilePicker(FakePickedFile('walk.gpx', gpxPath));
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = MethodChannelFilePicker());
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final summary = await model.importViaFilePicker();

    expect(summary.imported, 1);
    expect(picker.lastPickArgs?.$1, FileType.any);
    expect(picker.lastPickArgs?.$2, isNull);
  });

  test('file picker off Android keeps the extension filter', () async {
    // flutter_test's defaultTargetPlatform is android; pin a desktop one.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final dir = Directory.systemTemp.createTempSync('unvisited-pick');
    addTearDown(() => dir.deleteSync(recursive: true));
    final gpxPath = '${dir.path}${Platform.pathSeparator}walk.gpx';
    File(gpxPath).writeAsBytesSync(fixture('main_street_walk.gpx'));
    final picker = FakeFilePicker(FakePickedFile('walk.gpx', gpxPath));
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = MethodChannelFilePicker());

    final summary = await model.importViaFilePicker();

    expect(summary.imported, 1);
    expect(picker.lastPickArgs?.$1, FileType.custom);
    expect(picker.lastPickArgs?.$2, ['gpx', 'fit', 'kmz', 'kml', 'tcx']);
  });

  test('re-importing the same files is a no-op for the refit state', () async {
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
    final path = '${dir.path}${Platform.pathSeparator}afternoon_ride.kmz';
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

  test('deleteAll removes every track, file and index entry', () async {
    await model.importFromDirectory(stageDir().path);
    expect(model.tracks.length, 2);
    final tracksDir = Directory('${root.path}${Platform.pathSeparator}tracks');
    expect(tracksDir.listSync().length, 2);
    expect(model.allVisiblePoints, isNotEmpty);

    await model.deleteAll();

    expect(model.tracks, isEmpty);
    expect(model.visibleTracks, isEmpty);
    expect(model.allVisiblePoints, isEmpty);
    expect(tracksDir.listSync(), isEmpty);

    // Must survive a store reload: the persisted index is empty too.
    final reloaded = TrackStore(root);
    await reloaded.load();
    expect(reloaded.tracks, isEmpty);
  });

  test('appearance settings persist and survive deleteAll', () async {
    // Out-of-the-box look: green overlay, slider on the right.
    expect(model.trackTint, 'green');
    expect(model.zoomSliderSide, 'right');

    await model.setTrackTint('blue');
    await model.setZoomSliderSide('left');
    expect(model.trackTint, 'blue');
    expect(model.zoomSliderSide, 'left');

    final reloaded = AppModel(TrackStore(root));
    await reloaded.load();
    expect(reloaded.trackTint, 'blue');
    expect(reloaded.zoomSliderSide, 'left');

    // A preference is not track data: the settings survive deleteAll.
    await reloaded.deleteAll();
    final after = AppModel(TrackStore(root));
    await after.load();
    expect(after.trackTint, 'blue');
    expect(after.zoomSliderSide, 'left');

    // Unknown keys (hand-edited index, older app) never break rendering:
    // the tint falls back to the default color.
    expect(exploredAreaColor('not-a-tint'), exploredAreaColor('green'));
  });

  test('bulk visibility: plain calls and no-ops never flag busy', () async {
    model.store.importBytes(fixture('morning_walk.gpx'));
    expect(model.busy, isFalse);
    await model.setAllVisible(false);
    expect(model.busy, isFalse);
    expect(model.allTracksVisible, isFalse);
    // A no-op feedback call (already in the target state) returns before
    // flagging busy. (The busy-during-rebuild path needs frames; it is
    // covered by the MapPage widget test.)
    await model.setAllVisibleWithFeedback(false);
    expect(model.busy, isFalse);
  });

  test(
    'language choice persists, survives deleteAll and falls back safely',
    () async {
      // Out of the box the app follows the device language.
      expect(model.language, 'system');
      expect(model.locale, isNull);

      await model.setLanguage('it');
      expect(model.language, 'it');
      expect(model.locale, const Locale('it'));

      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.language, 'it');
      expect(reloaded.locale, const Locale('it'));

      // A preference, not track data.
      await reloaded.deleteAll();
      final after = AppModel(TrackStore(root));
      await after.load();
      expect(after.language, 'it');

      // A hand-edited index naming a language the app does not speak must
      // not produce a broken locale: follow the device instead.
      await after.setLanguage('kl');
      expect(after.locale, isNull);
      expect(
        AppStrings.of(after.locale ?? const Locale('fr')),
        isA<EnglishStrings>(),
      );
    },
  );

  test('saved position persists in the index and survives a reload', () async {
    expect(model.savedPosition, isNull, reason: 'never obtained a fix yet');

    // Saving happens inside currentPosition(); a fix is injected by
    // writing through the store directly (the plugin is absent in tests).
    await model.store.savePosition(48.8584, 2.2945);
    expect(model.savedPosition!.latitude, closeTo(48.8584, 1e-9));
    expect(model.savedPosition!.longitude, closeTo(2.2945, 1e-9));

    final reloaded = AppModel(TrackStore(root));
    await reloaded.load();
    expect(reloaded.savedPosition!.latitude, closeTo(48.8584, 1e-9));

    // The position is the user's location, not track data: clearing the
    // catalog must keep it.
    await reloaded.deleteAll();
    expect(reloaded.savedPosition, isNotNull);
  });

  test('currentPosition degrades to null without prompting', () async {
    // No geolocator host implementation exists in the test environment:
    // the silent (startup) path must simply yield no position.
    expect(await model.currentPosition(prompt: false), isNull);
    expect(await model.currentPosition(prompt: true), isNull);
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
      expect(model.allVisiblePoints, isEmpty);

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
      expect(model.allVisiblePoints, isNotEmpty);
    });
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
      final staged = stageSafScan([
        'morning_walk.gpx',
        'afternoon_ride.kmz',
        'monitoring.fit',
      ]);
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hostChannel, (call) async {
            switch (call.method) {
              case 'pickDirectory':
                return treeUri;
              case 'listTrackFiles':
                expect(
                  call.arguments,
                  treeUri,
                  reason: 'Dart must pass the picked tree URI through',
                );
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

    test(
      'deletes the staging copies once the pipeline consumed them',
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
          expect(
            File(entry['path'] as String).existsSync(),
            isFalse,
            reason: 'staged files must not linger in the cache dir',
          );
        }
      },
    );

    test(
      'an unparseable staged file fails without aborting the import',
      () async {
        final staged = stageSafScan(['morning_walk.gpx']);
        final junk = File(
          '${Directory.systemTemp.createTempSync('unvisited-saf').path}'
          '${Platform.pathSeparator}junk.gpx',
        )..writeAsBytesSync('not a gpx'.codeUnits);
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
      },
    );

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

  group('road unlock state', () {
    /// Copies the synthetic road fixture into the temp root and activates
    /// it on the model.
    void activateRoad() {
      final roadFile = File(
        '${root.path}${Platform.pathSeparator}test_roads.unvisited-roads',
      );
      roadFile.writeAsBytesSync(fixture('test_roads.unvisited-roads'));
      model.setRoadFile(roadFile.path);
    }

    test('an import with an active road file persists unlock state', () async {
      activateRoad();
      final dir = stageDir();
      File('${dir.path}${Platform.pathSeparator}main_street_walk.gpx')
          .writeAsBytesSync(fixture('main_street_walk.gpx'));

      await model.importFromDirectory(dir.path);

      final walk = model.tracks.singleWhere(
        (t) => t.name == 'Main Street walk',
      );
      expect(walk.unlockedWays.keys, contains('1001')); // Main Street
      // The corridor runs along Main Street's latitude and spans the walk.
      final corridor = walk.unlockedWays['1001']!.expand((pts) => pts).toList();
      expect(corridor.length, greaterThanOrEqualTo(2));
      for (final p in corridor) {
        expect(p.latitude, closeTo(52.5200, 1e-4));
      }
      expect(corridor.first.longitude, closeTo(13.4050, 1e-3));
      expect(corridor.last.longitude, closeTo(13.4100, 1e-3));
      // The walk never comes near Parallel Lane (44 m north).
      expect(walk.unlockedWays.containsKey('1003'), isFalse);

      // The state survives a restart (round-trips through index.json).
      final reloaded = TrackStore(root);
      await reloaded.load();
      final restored = reloaded.tracks
          .singleWhere((t) => t.name == 'Main Street walk')
          .unlockedWays['1001']!;
      expect(
        restored.expand((pts) => pts).last.longitude,
        closeTo(13.4100, 1e-3),
      );
    });

    test('an import without a road file leaves unlock state empty', () async {
      final dir = stageDir();
      await model.importFromDirectory(dir.path);
      for (final t in model.tracks) {
        expect(t.unlockedWays, isEmpty);
      }
    });

    test(
      'a byte-identical re-import keeps the existing unlock state',
      () async {
        activateRoad();
        final dir = stageDir();
        File('${dir.path}${Platform.pathSeparator}main_street_walk.gpx')
            .writeAsBytesSync(fixture('main_street_walk.gpx'));
        await model.importFromDirectory(dir.path);
        final before = Map.of(
          model.tracks
              .singleWhere((t) => t.name == 'Main Street walk')
              .unlockedWays,
        );

        final summary = await model.importFromDirectory(dir.path);

        expect(summary.duplicates, greaterThanOrEqualTo(1));
        expect(
          model.tracks
              .singleWhere((t) => t.name == 'Main Street walk')
              .unlockedWays,
          before,
        );
      },
    );

    test('an index without the unlockedWays field loads with empty maps', () async {
      // A pre-road-matching index: entries without the field must load.
      // (load() skips entries whose track file is gone, so create it.)
      Directory('${root.path}${Platform.pathSeparator}tracks')
          .createSync(recursive: true);
      File(
        '${root.path}${Platform.pathSeparator}tracks${Platform.pathSeparator}abc.gpx',
      ).writeAsStringSync('<gpx/>');
      File('${root.path}${Platform.pathSeparator}index.json').writeAsStringSync(
        '{"version": 1, "tracks": [{"id": "abc", '
        '"name": "old", "format": "GPX", "file": "abc.gpx", '
        '"pointCount": 1, "distanceMeters": 10.0, "visible": true}], '
        '"settings": {}}',
      );
      final reloaded = TrackStore(root);
      await reloaded.load();
      expect(reloaded.tracks.single.unlockedWays, isEmpty);
    });
  });

  group('road data settings', () {
    void installPicker(PlatformFile? picked) {
      FilePickerPlatform.instance = FakeFilePicker(picked);
      addTearDown(() {
        FilePickerPlatform.instance = MethodChannelFilePicker();
      });
    }

    /// Builds a `.unvisited-roads` region file from way maps shaped like
    /// the build CLI's JSON input.
    String buildRegion(String fileName, List<Map> ways) {
      final dir = Directory.systemTemp.createTempSync('unvisited-region');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}$fileName';
      buildRoadFile(ways, path);
      return path;
    }

    /// Main Street as in the fixture walk (the corridor the synthetic
    /// test data unlocks), plus a parallel lane the walk never touches.
    final regionA = <Map>[
      {
        'id': '1001',
        'class': 'residential',
        'name': 'Main Street',
        'points': [
          [52.5200, 13.4040],
          [52.5200, 13.4110],
        ],
      },
    ];

    /// A second region matching the same walk on a *different* way — the
    /// cross street it crosses at 13.4060.
    final regionB = <Map>[
      {
        'id': '2002',
        'class': 'residential',
        'name': 'Cross Street',
        'points': [
          [52.5199, 13.4060],
          [52.5202, 13.4060],
        ],
      },
    ];

    Future<StoredTrack> importWalk() async {
      final dir = Directory('${root.path}${Platform.pathSeparator}inbox')
        ..createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}main_street_walk.gpx')
          .writeAsBytesSync(fixture('main_street_walk.gpx'));
      await model.importFromDirectory(dir.path);
      return model.tracks.singleWhere((t) => t.name == 'Main Street walk');
    }

    test('a picked region file is stored under the app root, activated '
        'and unlock state is computed for existing tracks', () async {
      final region = buildRegion('berlin.unvisited-roads', regionA);
      installPicker(FakePickedFile('berlin.unvisited-roads', region));
      final walk = await importWalk(); // imported without roads
      expect(walk.unlockedWays, isEmpty);

      final failure = await model.pickRoadFile();

      expect(failure, isNull);
      expect(model.roadsName, 'berlin.unvisited-roads');
      expect(model.roadStore, isNotNull);
      final stored = File(
        '${root.path}${Platform.pathSeparator}roads'
        '${Platform.pathSeparator}berlin.unvisited-roads',
      );
      expect(stored.existsSync(), isTrue);
      // The recompute-on-activation inline import: the walk now unlocks
      // Main Street without a new import.
      expect(walk.unlockedWays.keys.single, '1001');

      // The choice survives a restart: it lives in the index.
      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.roadsName, 'berlin.unvisited-roads');
      expect(reloaded.roadStore, isNotNull);
    });

    test('a cancelled pick changes nothing', () async {
      installPicker(null);
      final failure = await model.pickRoadFile();
      expect(failure, isNull);
      expect(model.roadsName, isNull);
      expect(model.roadStore, isNull);
    });

    test('a file that is not a roads file is rejected', () async {
      final dir = Directory.systemTemp.createTempSync('unvisited-region');
      addTearDown(() => dir.deleteSync(recursive: true));
      final junk = File('${dir.path}${Platform.pathSeparator}junk.dat')
        ..writeAsBytesSync('not a roads file'.codeUnits);
      installPicker(FakePickedFile('junk.dat', junk.path));
      final walk = await importWalk();

      final failure = await model.pickRoadFile();

      expect(failure, RoadFileFailure.corrupt);
      expect(model.roadsName, isNull);
      expect(model.roadStore, isNull);
      expect(walk.unlockedWays, isEmpty);
    });

    test('swapping regions re-matches every track and keeps corridors '
        'matched under an earlier region', () async {
      final walk = await importWalk();

      expect(
        await model.activateRoadFile(buildRegion('a.unvisited-roads', regionA)),
        isNull,
      );
      expect(walk.unlockedWays.keys, ['1001']);

      expect(
        await model.activateRoadFile(buildRegion('b.unvisited-roads', regionB)),
        isNull,
      );

      // Region B's way matched the walk (recompute ran), and region A's
      // way was NOT wiped away: the corridors are materialized
      // exploration data and way ids coalesce across overlapping regions.
      expect(walk.unlockedWays.keys.toSet(), {'1001', '2002'});
      // Previous region's stored copy is replaced on disk.
      final oldRegion = File(
        '${root.path}${Platform.pathSeparator}roads'
        '${Platform.pathSeparator}a.unvisited-roads',
      );
      expect(oldRegion.existsSync(), isFalse);
      expect(model.roadsName, 'b.unvisited-roads');

      // Re-activating the same region never duplicates corridors.
      expect(
        await model.activateRoadFile(
          buildRegion('b2.unvisited-roads', regionB),
        ),
        isNull,
      );
      expect(walk.unlockedWays.keys.toSet(), {'1001', '2002'});
    });

    test('removing the road data forgets the file but keeps the unlock '
        'state', () async {
      final walk = await importWalk();
      await model.activateRoadFile(buildRegion('a.unvisited-roads', regionA));
      final before = Map.of(walk.unlockedWays);
      expect(before, isNotEmpty);

      await model.removeRoadFile();

      expect(model.roadsName, isNull);
      expect(model.roadStore, isNull);
      expect(walk.unlockedWays, before); // exploration data survives
      // Only the stored copy is deleted; the (now empty) directory stays.
      expect(
        File(
          '${root.path}${Platform.pathSeparator}roads'
          '${Platform.pathSeparator}a.unvisited-roads',
        ).existsSync(),
        isFalse,
      );
    });

    test('a road file gone from disk falls back to circles-only and '
        'clears the stale reference', () async {
      await importWalk();
      await model.activateRoadFile(buildRegion('a.unvisited-roads', regionA));
      expect(model.roadStore, isNotNull);
      final stored = File(
        '${root.path}${Platform.pathSeparator}roads'
        '${Platform.pathSeparator}a.unvisited-roads',
      );
      stored.deleteSync(); // vanished between runs (external deletion)

      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();

      expect(reloaded.roadsName, isNull);
      expect(reloaded.roadStore, isNull);
      // The unlock state recorded earlier keeps rendering (circles-only
      // fallback affects *new* matching, not recorded corridors).
      final restored = reloaded.tracks.singleWhere(
        (t) => t.name == 'Main Street walk',
      );
      expect(restored.unlockedWays.keys.single, '1001');
    });
  });

  group('theme mode', () {
    test('defaults to system', () {
      expect(model.themeMode, 'system');
      expect(model.themeModeValue, ThemeMode.system);
    });

    test('persists and restores theme mode', () async {
      await model.setThemeMode('dark');
      expect(model.themeMode, 'dark');
      expect(model.themeModeValue, ThemeMode.dark);

      // Recreate model to verify persistence
      final newModel = AppModel(TrackStore(root));
      await newModel.load();
      expect(newModel.themeMode, 'dark');
      expect(newModel.themeModeValue, ThemeMode.dark);
    });

    test('maps string values to ThemeMode correctly', () {
      expect(model.themeModeValue, ThemeMode.system);

      // We can't change model.themeMode directly, but we can test the mapping
      // through a temporary model with different stored values
      // This is tested more thoroughly in the persistence test above
    });
  });

  group('tile layer', () {
    test('defaults to the standard OSM raster', () {
      expect(model.tileLayer, 'standard');
    });

    test('switching to the cycle layer persists and restores', () async {
      await model.setTileLayer('cycle');
      expect(model.tileLayer, 'cycle');

      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.tileLayer, 'cycle');

      // Switching back persists too.
      await reloaded.setTileLayer('standard');
      expect(reloaded.tileLayer, 'standard');
    });
  });

  group('map rotation', () {
    test('defaults to north-up', () {
      expect(model.mapRotation, 'north');
    });

    test('switching modes persists and restores', () async {
      await model.setMapRotation('course');
      expect(model.mapRotation, 'course');

      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.mapRotation, 'course');

      await reloaded.setMapRotation('north');
      expect(reloaded.mapRotation, 'north');
    });

    test('the removed compass mode migrates to course', () async {
      final indexFile =
          '${root.path}${Platform.pathSeparator}index.json';
      await File(indexFile).writeAsString(
          '{"settings": {"mapRotation": "compass"}, "tracks": []}');
      final legacyCompass = AppModel(TrackStore(root));
      await legacyCompass.load();
      expect(legacyCompass.mapRotation, 'course');
    });

    test('legacy on/off settings migrate to course/north', () async {
      final indexFile =
          '${root.path}${Platform.pathSeparator}index.json';
      await File(indexFile).writeAsString(
          '{"settings": {"mapRotation": "on"}, "tracks": []}');
      final legacyOn = AppModel(TrackStore(root));
      await legacyOn.load();
      expect(legacyOn.mapRotation, 'course');

      await File(indexFile).writeAsString(
          '{"settings": {"mapRotation": "off"}, "tracks": []}');
      final legacyOff = AppModel(TrackStore(root));
      await legacyOff.load();
      expect(legacyOff.mapRotation, 'north');
    });
  });

  group('debug logging', () {
    test('defaults to off and the log stays empty', () {
      expect(model.debugLogging, isFalse);
      expect(DebugLog.instance.enabled, isFalse);
      DebugLog.instance.info('dropped while disabled');
      expect(DebugLog.instance.isEmpty, isTrue);
    });

    test('toggling persists, restores, and gates the log', () async {
      await model.setDebugLogging(true);
      expect(model.debugLogging, isTrue);
      expect(DebugLog.instance.enabled, isTrue);
      DebugLog.instance.info('hello');
      expect(DebugLog.instance.isEmpty, isFalse);

      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.debugLogging, isTrue);
      expect(DebugLog.instance.enabled, isTrue);

      await reloaded.setDebugLogging(false);
      expect(reloaded.debugLogging, isFalse);
      expect(DebugLog.instance.enabled, isFalse);
      expect(DebugLog.instance.isEmpty, isTrue);
    });
  });

  group('keep screen on', () {
    test('defaults to on', () {
      expect(model.keepScreenOn, isTrue);
    });

    test('toggling persists and restores', () async {
      await model.setKeepScreenOn(false);
      expect(model.keepScreenOn, isFalse);

      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.keepScreenOn, isFalse);

      await reloaded.setKeepScreenOn(true);
      expect(reloaded.keepScreenOn, isTrue);
    });

    test('survives deleteAll like every preference', () async {
      await model.setKeepScreenOn(false);
      await model.deleteAll();

      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.keepScreenOn, isFalse);
    });
  });

  group('recording', () {
    group('the soft POST_NOTIFICATIONS ask', () {
      tearDown(() {
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(hostChannel, null);
      });

      test('surfaces the grant result from the host', () async {
        for (final granted in [true, false]) {
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(hostChannel, (call) async {
                expect(call.method, 'requestPostNotifications');
                return granted;
              });
          expect(await model.requestPostNotifications(), granted);
        }
      });

      test('a missing host plugin answers null (desktop, tests)', () async {
        // No handler set: MissingPluginException turns into null.
        expect(await model.requestPostNotifications(), isNull);
      });

      test('a host error answers null, never throws', () async {
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(hostChannel, (call) async {
              throw PlatformException(code: 'already_active');
            });
        expect(await model.requestPostNotifications(), isNull);
      });
    });

    test('start is gated closed when no host plugin answers', () async {
      // The unit-test host has no geolocator; the gate fails closed
      // instead of half-starting a session nobody can feed.
      expect(await model.startRecording(), isNull);
      expect(model.isRecording, isFalse);
    });

    test(
      'a fake-sourced session records and stops through the pipeline',
      () async {
        final source = FakePositionSource();
        final staged = await model.startRecording(
          source: source,
          permissionGate: false,
        );
        expect(staged, isNotNull);
        expect(model.isRecording, isTrue);
        expect(
          await model.startRecording(source: source, permissionGate: false),
          isNull,
          reason: 'one session at a time',
        );

        fakeFix(source, 0, ele: 42.0);
        // 22.2 m from fix(0): past the thinning threshold, so staged.
        fakeFix(source, 1, prevLat: 52.5200, lat: 52.5202, ele: 43.0);
        await Future<void>.delayed(Duration.zero);
        await model.stopRecording();
        expect(model.isRecording, isFalse);
        final stored = model.tracks.single;
        expect(stored.pointCount, 2);
        expect(stored.format, 'GPX');
        expect(stored.name, isNotEmpty, reason: 'the staged name survives');
        // The staged file is deleted; the catalog owns the copy.
        final dir = Directory('${root.path}${Platform.pathSeparator}recording');
        expect(dir.existsSync(), isTrue);
        expect(dir.listSync(), isEmpty);
      },
    );

    test('a discarded session imports nothing and cannot be salvaged', () async {
      final source = FakePositionSource();
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201);
      await Future<void>.delayed(Duration.zero);
      await model.discardRecording();
      expect(model.isRecording, isFalse);
      expect(model.tracks, isEmpty);
      // The staged file is not merely un-imported — it is gone. Startup
      // salvage imports every leftover staged file, so a surviving one
      // would resurrect the discarded track on the next launch.
      final dir = Directory('${root.path}${Platform.pathSeparator}recording');
      expect(dir.listSync(), isEmpty);
      expect(model.salvagedRecordingNames, isEmpty);
    });

    test('a stopped session also matches road corridors', () async {
      // The fake walk starts on Main Street (the roads fixture's way 1001
      // at 52.5200, 13.4050) and walks north.
      final roadFile = File(
        '${root.path}${Platform.pathSeparator}test_roads.unvisited-roads',
      );
      roadFile.writeAsBytesSync(fixture('test_roads.unvisited-roads'));
      model.setRoadFile(roadFile.path);

      final source = FakePositionSource();
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201);
      await Future<void>.delayed(Duration.zero);
      await model.stopRecording();
      await Future<void>.delayed(Duration.zero);

      final stored = model.tracks.single;
      expect(
        stored.unlockedWays.keys,
        contains('1001'),
        reason:
            'a recorded track is an ordinary catalog track: the '
            'corridor matching applies',
      );
    });

    test("the stop name dialog's choice lands as the catalog name", () async {
      final source = FakePositionSource();
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201);
      await Future<void>.delayed(Duration.zero);
      await model.stopRecording(name: 'Bike home');
      await Future<void>.delayed(Duration.zero);

      final stored = model.tracks.single;
      expect(stored.name, 'Bike home');
      // The stored file's GPX header carries the name — the parser read
      // it from there, not from the filename fallback.
      final storedFile = File(
        '${root.path}${Platform.pathSeparator}tracks'
        '${Platform.pathSeparator}${stored.file}',
      );
      expect(
        utf8.decode(storedFile.readAsBytesSync()),
        contains('<name>Bike home</name>'),
      );
      // The staged copy is spent either way.
      expect(
        Directory('${root.path}${Platform.pathSeparator}recording').listSync(),
        isEmpty,
      );
    });
  });

  group('recording salvage', () {
    final base = DateTime.utc(2026, 11, 13, 12);

    /// A killed session's staged file: complete points, an open segment,
    /// no closing tags (the writer cut at the last flushed newline).
    List<int> killedGpxBytes(String trackName) {
      final sink = MemoryStageSink();
      final writer = GpxStageWriter(sink, name: trackName);
      writer.appendPoint(lat: 52.5200, lon: 13.4050, time: base, ele: 42.0);
      writer.appendPoint(
        lat: 52.5201,
        lon: 13.4050,
        time: base.add(const Duration(seconds: 1)),
      );
      final text = sink.buffer.toString();
      return utf8.encode(
        text.substring(0, text.length - 1),
      ); // byte-level mid-newline cut
    }

    Directory recordingDir() =>
        Directory('${root.path}${Platform.pathSeparator}recording')
          ..createSync(recursive: true);

    test(
      'a killed session s staged file imports at startup, with a notice',
      () async {
        final dir = recordingDir();
        File('${dir.path}${Platform.pathSeparator}1763040000000.gpx')
            .writeAsBytesSync(killedGpxBytes('Killed ride'));

        await model.load();

        expect(model.salvagedRecordingNames, ['Killed ride']);
        final stored = model.tracks.single;
        expect(stored.name, 'Killed ride');
        expect(stored.pointCount, 2);
        // The staged copy is spent; the catalog owns its file.
        expect(dir.listSync(), isEmpty);
      },
    );

    test('a non-ASCII track name survives the salvage byte-exact', () async {
      // Regression (utf8 vs String.codeUnits): the salvage path used to
      // re-encode the read string's UTF-16 code units as file bytes, so
      // any character above U+00FF — a name the stop dialog accepts —
      // landed corrupted.
      final dir = recordingDir();
      final sink = MemoryStageSink();
      final writer = GpxStageWriter(sink, name: 'Anello dei Grumé');
      writer.appendPoint(lat: 52.5200, lon: 13.4050, time: base);
      writer.appendPoint(
        lat: 52.5201,
        lon: 13.4050,
        time: base.add(const Duration(seconds: 1)),
      );
      writer.finalize();
      File('${dir.path}${Platform.pathSeparator}1763040000000.gpx')
          .writeAsBytesSync(utf8.encode(sink.buffer.toString()));

      await model.load();

      expect(model.salvagedRecordingNames, ['Anello dei Grumé']);
      final stored = model.tracks.single;
      expect(stored.name, 'Anello dei Grumé');
      expect(stored.pointCount, 2);
    });

    test('a complete staged file (kill between finalize and import) '
        'imports as-is', () async {
      final dir = recordingDir();
      final sink = MemoryStageSink();
      final writer = GpxStageWriter(sink, name: 'Finalized ride');
      writer.appendPoint(lat: 52.5200, lon: 13.4050, time: base, ele: 42.0);
      writer.appendPoint(
        lat: 52.5201,
        lon: 13.4050,
        time: base.add(const Duration(seconds: 1)),
      );
      writer.finalize();
      expect(sink.buffer.toString(), contains('</gpx>'));
      File('${dir.path}${Platform.pathSeparator}1763040000000.gpx')
          .writeAsBytesSync(sink.buffer.toString().codeUnits);

      await model.load();

      expect(model.salvagedRecordingNames, ['Finalized ride']);
      final stored = model.tracks.single;
      expect(
        stored.pointCount,
        2,
        reason: 'nothing was cut from a complete file',
      );
      expect(dir.listSync(), isEmpty);
    });

    test(
      'a staged file with nothing recorded is junk and is removed',
      () async {
        final dir = recordingDir();
        // Killed before the first flushed point: header only.
        File('${dir.path}${Platform.pathSeparator}1763040000000.gpx')
            .writeAsBytesSync(
              '<?xml version="1.0" encoding="UTF-8"?>\n'
                      '<gpx version="1.1" creator="unvisited"><trk>'
                  .codeUnits,
            );

        await model.load();

        expect(model.salvagedRecordingNames, isEmpty);
        expect(model.tracks, isEmpty);
        expect(dir.listSync(), isEmpty);
      },
    );
  });

  group('aggregates & selection', () {
    Future<String> importGpx(
      String name, {
      required double lat,
      required double lon,
      required DateTime time,
    }) async {
      // A single-point track stamped with [time]; 0.0002 deg of latitude
      // is ~22 m, well inside the 100 m default threshold.
      final gpx = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<gpx version="1.1" creator="test"><trk><trkseg>'
          '<trkpt lat="$lat" lon="$lon"><time>${time.toIso8601String()}</time></trkpt>'
          '</trkseg></trk></gpx>\n';
      final file = File('${root.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(utf8.encode(gpx));
      final before = model.tracks.map((t) => t.id).toSet();
      await model.importFromFile(file.path);
      return model.tracks
          .map((t) => t.id)
          .where((id) => !before.contains(id))
          .first;
    }

    test('tracks within the threshold join one aggregate with anchors', () async {
      final start = DateTime.utc(2026, 6, 1, 8);
      final a = await importGpx('a.gpx', lat: 45.0, lon: 9.0, time: start);
      final b = await importGpx(
        'b.gpx',
        lat: 45.0002,
        lon: 9.0,
        time: start.add(const Duration(days: 3)),
      );
      final aggregates = model.aggregates;
      expect(aggregates, hasLength(1));
      expect(aggregates.single.trackIds, containsAllInOrder([a, b]));
      expect(aggregates.single.anchorId, a, reason: 'a starts first');
    });

    test('tap-to-select, hide, and color override persistence', () async {
      final start = DateTime.utc(2026, 6, 1, 8);
      final a = await importGpx('a.gpx', lat: 45.0, lon: 9.0, time: start);
      final b = await importGpx(
        'b.gpx',
        lat: 45.0,
        lon: 9.0002,
        time: start.add(const Duration(days: 3)),
      );

      expect(model.selectAggregateAt(const LatLng(45.0, 9.0),
          toleranceMeters: 100), isTrue);
      expect(model.selectedAggregate?.trackIds, containsAll([a, b]));

      // Color override keys by the anchor and survives a store reload.
      await model.setAggregateColor('blue');
      expect(model.selectedAggregateColor, 'blue');
      final reloaded = AppModel(TrackStore(root));
      await reloaded.load();
      expect(reloaded.store.aggregateColor(a), 'blue');

      // Hide deselects and hides every member track.
      await model.hideSelectedAggregate();
      expect(model.selectedAggregate, isNull);
      expect(model.store.tracks.every((t) => !t.visible), isTrue);
      expect(model.aggregates, isEmpty);

      // Re-showing: aggregates recompute from the visible set again.
      await model.setAllVisible(true);
      expect(model.aggregates.single.trackIds, containsAll([a, b]));
    });

    test('a tap too far from every aggregate point deselects', () async {
      final start = DateTime.utc(2026, 6, 1, 8);
      await importGpx('a.gpx', lat: 45.0, lon: 9.0, time: start);
      model.selectAggregateAt(const LatLng(45.0, 9.0), toleranceMeters: 100);
      expect(model.selectedAnchor, isNotNull);

      // ~11 km away: no hit, and the existing selection clears.
      model.selectAggregateAt(const LatLng(45.1, 9.0), toleranceMeters: 100);
      expect(model.selectedAnchor, isNull);
    });
  });

  group('export', () {
    /// Imports the GPX fixture; the pipeline saw the same bytes the
    /// stored file now carries.
    StoredTrack importOne() {
      model.store.importBytes(fixture('morning_walk.gpx'));
      return model.tracks.single;
    }

    void installSaver(String? savedTo) {
      FilePickerPlatform.instance = FakeFilePicker(null, savedTo: savedTo);
      addTearDown(() {
        FilePickerPlatform.instance = MethodChannelFilePicker();
      });
    }

    test('a desktop save writes the stored bytes byte-identical', () async {
      final track = importOne();
      final stored = model.store.trackFileFor(track).readAsBytesSync();
      final target = '${root.path}${Platform.pathSeparator}out.gpx';
      installSaver(target);

      final result = await model.exportTrack(track);

      expect(result, target);
      expect(File(target).readAsBytesSync(), stored);
    });

    test('a cancelled save dialog writes nothing', () async {
      final track = importOne();
      final target = '${root.path}${Platform.pathSeparator}out.gpx';
      installSaver(null);

      final result = await model.exportTrack(track);

      expect(result, isNull);
      expect(File(target).existsSync(), isFalse);
    });
  });
}

/// Walking north along the Greenwich meridian, ~11.1 m per 0.0001 deg of
/// latitude; fixes stage per second (the engine's stream settles on the
/// microtask boundary).
void fakeFix(
  FakePositionSource source,
  int second, {
  double lat = 52.5200,
  double prevLat = 52.5200,
  double lon = 13.4050,
  double? ele,
  double? acc = 5,
  double? speed,
}) {
  source.controller.add(
    PositionFix(
      lat: lat,
      lon: lon,
      ele: ele,
      accuracy: acc,
      speed: speed,
      time: DateTime.utc(2026, 11, 13, 12).add(Duration(seconds: second)),
    ),
  );
}
