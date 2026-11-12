import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';
import 'package:unvisited/ui/fog_of_war.dart';
import 'package:unvisited/ui/map_page.dart';
import 'package:unvisited/ui/track_colors.dart';

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

  testWidgets('header actions carry labels naming what they do',
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

    for (final label in const ['Import', 'Locate', 'Tracks', 'Settings']) {
      expect(find.text(label), findsOneWidget,
          reason: 'the $label action must be captioned');
    }
    // Fit is disabled on the empty map, but still shows its label.
    expect(find.text('Fit'), findsOneWidget);
  });

  testWidgets('visited tracks plot as fog-of-war unlock circles', (tester) async {
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
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('eiffel_ride.tcx'));
    expect(model.tracks.length, 2);

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();

    // The polylines are gone by design: the fog-of-war overlay replaces
    // them — one translucent circle per unlocked grid cell.
    expect(find.byType(PolylineLayer), findsNothing);
    final circles = tester.widget<CircleLayer>(find.byType(CircleLayer)).circles;
    expect(circles, isNotEmpty);
    expect(circles.every((c) => c.useRadiusInMeter), isTrue,
        reason: 'unlock circles are sized as real ground areas');
    expect(circles.every((c) => c.color == exploredAreaColor('green')),
        isTrue,
        reason: 'one uniform exploration tint, map stays legible');
    expect(circles.every((c) => c.radius >= unlockRadiusMeters - 1e-9),
        isTrue,
        reason: 'never smaller than the base unlock radius');
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

    // Two 'Settings' texts: the header caption behind the modal sheet
    // and the sheet's own header.
    expect(find.text('Settings'), findsNWidgets(2));
    expect(find.text('Unvisited'), findsOneWidget, // About card
        reason: 'the app-bar title is gone; only the About card names it');
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
    await tester.ensureVisible(find.text('Delete all tracks'));
    await tester.pump();
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

  testWidgets('lateral zoom slider steps and drags the camera zoom',
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
    await tester.pump();

    double cameraZoom() => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera
        .zoom;
    expect(cameraZoom(), 13.0); // Berlin start camera

    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(cameraZoom(), 14.0);

    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pump();
    expect(cameraZoom(), 13.0);

    // Full upward rail drag tops out at the OSM zoom limit, downward at
    // the world floor; the clamps also apply to the header's old buttons.
    await tester.drag(
        find.byKey(const ValueKey('zoom-track')), const Offset(0, -400));
    await tester.pump();
    expect(cameraZoom(), 19.0);

    await tester.drag(
        find.byKey(const ValueKey('zoom-track')), const Offset(0, 400));
    await tester.pump();
    expect(cameraZoom(), 3.0);
  });

  testWidgets('zoom slider hugs the configured screen edge', (tester) async {
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
    await TrackStore(root).saveZoomSliderSide('left');
    final model = AppModel(TrackStore(root));
    await model.load();
    expect(model.zoomSliderSide, 'left');

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();

    Positioned sliderOf() => tester.widget<Positioned>(
        find.ancestor(
            of: find.byKey(const ValueKey('zoom-track')),
            matching: find.byType(Positioned)));

    expect(sliderOf().left, 12, reason: 'setting says left edge');
    expect(sliderOf().right, isNull);

    await model.setZoomSliderSide('right');
    await tester.pump();
    expect(sliderOf().left, isNull);
    expect(sliderOf().right, 12, reason: 'setting says right edge');
  });

  testWidgets('settings sheet picks the track color and slider side',
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
    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Both appearance controls are present with their choices visible.
    expect(find.text('Track color'), findsOneWidget);
    expect(find.text('Zoom slider'), findsOneWidget);
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Right'), findsOneWidget);

    // A tint pick recolors the map behind the still-open sheet and
    // persists in the index.
    await tester.tap(find.byTooltip('Blue'));
    await tester.pump();
    final circles =
        tester.widget<CircleLayer>(find.byType(CircleLayer)).circles;
    expect(circles.every((c) => c.color == exploredAreaColor('blue')),
        isTrue);
    expect(model.trackTint, 'blue');
    final reloaded = TrackStore(root);
    await reloaded.load();
    expect(reloaded.tint, 'blue');

    // So does a slider edge switch (scrolled into view first — the sheet
    // grew past one screen when it gained the appearance controls).
    await tester.ensureVisible(find.text('Left'));
    await tester.pump();
    await tester.tap(find.text('Left'));
    await tester.pump();
    expect(model.zoomSliderSide, 'left');
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
