import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';
import 'package:unvisited/ui/map_page.dart';

import 'helpers.dart';

void main() {
  Directory createRoot() {
    final root = Directory.systemTemp.createTempSync('unvisited-store');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    return root;
  }

  testWidgets('MapPage builds its tile layer without crashing', (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // See above.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();

    await tester.pumpWidget(
      MaterialApp(home: MapPage(model: model, cacheDir: cache, versionFuture: Future.value('2026-11-12 12:00'))),
    );
    await tester.pump();

    // A const tile provider headers map is unmodifiable; TileLayer's
    // constructor inserts a default User-Agent into it and throws.
    expect(tester.takeException(), isNull);
    expect(find.byType(FlutterMap), findsOneWidget);
    // Writable cache dir: the built-in caching provider stays in charge.
    final provider =
        (tester.widget<TileLayer>(find.byType(TileLayer)).tileProvider
                as NetworkTileProvider)
            .cachingProvider;
    expect(provider, isNull);
  });

  testWidgets('unusable cache dir disables caching instead of stalling tiles',
      (tester) async {
    final root = createRoot();
    // A path whose parent chain runs through a plain file is not creatable
    // - deterministic on every filesystem, no permission tricks needed.
    final blocker = File(
        '${Directory.systemTemp.createTempSync('unvisited-blocker').path}'
        '${Platform.pathSeparator}blocker')
      ..createSync();
    addTearDown(() {
      try {
        blocker.parent.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: Directory('${blocker.path}${Platform.pathSeparator}cache'),
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Tiles must degrade to network-only, not to a provider whose tile
    // reads can never complete.
    final provider =
        (tester.widget<TileLayer>(find.byType(TileLayer)).tileProvider
                as NetworkTileProvider)
            .cachingProvider;
    expect(provider, isA<DisabledMapCachingProvider>());
  });

  testWidgets('drawer select/deselect all button toggles every track',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // See above.
      }
    });
    final model = AppModel(TrackStore(root));
    // Imports go through the synchronous store path: directory scanning is
    // real async I/O, which a widget test's fake async zone never completes.
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('eiffel_ride.tcx'));
    expect(model.tracks.length, 2);

    await tester.pumpWidget(
      MaterialApp(home: MapPage(model: model, cacheDir: cache, versionFuture: Future.value('2026-11-12 12:00'))),
    );
    await tester.tap(find.byTooltip('Tracks'));
    // Fixed pumps, not pumpAndSettle: the tile-backed map keeps scheduling
    // frames, so the tree never settles inside the test environment.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.allTracksVisible, isTrue);
    await tester.tap(find.byTooltip('Deselect all tracks'));
    await tester.pump();
    expect(model.allTracksVisible, isFalse);
    expect(find.byTooltip('Select all tracks'), findsOneWidget);

    await tester.tap(find.byTooltip('Select all tracks'));
    await tester.pump();
    expect(model.allTracksVisible, isTrue);
  });

  testWidgets('track tile delete button removes the track',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    expect(model.tracks.length, 1);

    await tester.pumpWidget(
      MaterialApp(home: MapPage(model: model, cacheDir: cache, versionFuture: Future.value('2026-11-12 12:00'))),
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final tracksDir = Directory('${root.path}${Platform.pathSeparator}tracks');
    expect(tracksDir.listSync().length, 1);

    await tester.tap(find.byTooltip('Delete track'));
    await tester.pump();

    expect(model.tracks, isEmpty);
    expect(tracksDir.listSync(), isEmpty);
  });

  testWidgets('settings sheet shows the About card and delete-all entry',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    expect(model.tracks.length, 1);

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 17:41'),
      ),
    ));

    await tester.tap(find.byTooltip('Settings'));
    // Fixed pumps, not pumpAndSettle: the tile-backed map never settles.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Settings'), findsOneWidget);
    // Once in the app bar title, once in the About card.
    expect(find.text('Unvisited'), findsNWidgets(2));
    expect(find.text('Build date: 2026-11-12 17:41'), findsOneWidget);
    expect(find.text('Delete all tracks'), findsOneWidget);
    expect(find.text('1 stored'), findsOneWidget);
  });

  testWidgets('settings delete-all removes files only after confirmation',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('eiffel_ride.tcx'));
    final tracksDir = Directory('${root.path}${Platform.pathSeparator}tracks');
    expect(tracksDir.listSync().length, 2);

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete all tracks'));
    await tester.pump(const Duration(milliseconds: 300));

    // Confirmation prompt first: nothing is deleted until confirmed.
    expect(find.text('Delete all tracks?'), findsOneWidget);
    expect(tracksDir.listSync().length, 2);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.tracks, isEmpty);
    expect(tracksDir.listSync(), isEmpty);
  });

  testWidgets('one Import button offers files and folder import',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));

    await tester.tap(find.byTooltip('Import tracks'));
    // Fixed pumps, not pumpAndSettle: the tile-backed map never settles.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Track files'), findsOneWidget);
    expect(find.text('A folder'), findsOneWidget);
  });

  testWidgets('map starts at the last saved position when there are no tracks',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.store.savePosition(-33.8688, 151.2093);
    await model.load();

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final center = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .options
        .initialCenter;
    expect(center.latitude, closeTo(-33.8688, 1e-9));
    expect(center.longitude, closeTo(151.2093, 1e-9));
  });

  testWidgets('locate button reports when no position is available',
      (tester) async {
    // The header now packs many actions; give the bar enough width that
    // the locate button is actually tappable.
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // The real geolocator channel has no host implementation in the test
    // environment (it would hang the fake async zone); mock a permanent
    // permission denial instead.
    const geolocatorChannel = MethodChannel('flutter.baseflow.com/geolocator');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(geolocatorChannel, (call) async {
      switch (call.method) {
        case 'checkPermission':
        case 'requestPermission':
          return 1; // LocationPermission.deniedForever
      }
      fail('unexpected geolocator method ${call.method}');
    });
    addTearDown(() {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(geolocatorChannel, null);
    });
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The test host has no location plugin: the graceful toast, not a
    // crash.
    expect(find.textContaining('Location unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup fit goes through the guarded initialCameraFit',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });

    final emptyModel = AppModel(TrackStore(root));
    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: emptyModel,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    expect(
      tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .options
          .initialCameraFit,
      isNull,
      reason: 'no tracks: keep the plain Berlin start camera',
    );

    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    expect(
      tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .options
          .initialCameraFit,
      isNotNull,
      reason: 'saved tracks: fit at startup via the engine-guarded path',
    );
  });
}
