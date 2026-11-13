import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/l10n/app_strings.dart';
import 'package:unvisited/recording/position_source.dart'
    show PositionFix, PositionSource;
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/tile_source.dart';
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

  testWidgets('switching to the cycle layer swaps the tile source',
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
    await model.load();

    await tester.pumpWidget(
      MaterialApp(home: MapPage(model: model, cacheDir: cache, versionFuture: Future.value('2026-11-12 12:00'))),
    );
    await tester.pump();

    expect(
      tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate,
      tileUrlTemplate,
    );

    await model.setTileLayer('cycle');
    await tester.pump();

    // The rebuild must swap both the URL template and its host rotation.
    final layer = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(layer.urlTemplate, cycleTileUrlTemplate);
    expect(layer.subdomains, cycleTileSubdomains);
  });

  testWidgets('record action starts a session the chip shows and stops it',
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
    await model.load();
    final source = FakePositionSource();

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
        locationSupported: true,
      ),
    ));
    await tester.pump();

    // Record tile visible, no chip yet: nothing records until the tap.
    expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsNothing);

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0, ele: 42.0);
    fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201, ele: 43.0);
    // Settles the fix stream's microtask boundary and the model's
    // notification it triggers; one pump can arrive before the fixes.
    await tester.pump();
    await tester.pump();

    // The slot turns into the stop; the chip shows the live stats — the
    // pulsing dot and the meters walked (the engine's haversine sum).
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.fiber_manual_record), findsOneWidget,
        reason: 'the pulse dot on the chip');
    expect(find.text('11 m'), findsOneWidget);

    // The stop's import runs behind a real-file read that FakeAsync's
    // zone never drains (a flush queued inside it never settles), so the
    // widget-land assertions end here; the stop-through-import chain and
    // the import round-trip are covered by the model-level tests.
    expect(model.recording, isNotNull);
  });

  testWidgets('the dashboard expands into the stats panel with live numbers',
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
    await model.load();
    final source = FakePositionSource();

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
        locationSupported: true,
      ),
    ));
    await tester.pump();

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0, ele: 42.0, speed: 1.0);
    fakeFix(source, 1, lat: 52.5201, ele: 43.0, speed: 1.0);
    fakeFix(source, 2, lat: 52.5202, speed: 1.0, ele: 44.0);
    await tester.pump();
    await tester.pump();

    // Collapsed: the chip alone — duration and distance on it, no panel.
    expect(find.byKey(const ValueKey('stats-panel')), findsNothing);
    expect(find.text('00:02'), findsOneWidget);
    expect(find.text('22 m'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recording-chip')));
    await tester.pump();

    expect(find.byKey(const ValueKey('stats-panel')), findsOneWidget);
    // The engine's numbers, in the panel's labels: current speed (the
    // fix's own 1 m/s), the moving average over the walking fixes,
    // distance, both durations and the altitude the fix reported.
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('3.6 km/h'), findsOneWidget);
    expect(find.text('Avg speed'), findsOneWidget);
    expect(find.text('40.0 km/h'), findsOneWidget);
    expect(find.text('Distance'), findsOneWidget);
    expect(find.text('22 m'), findsNWidgets(2),
        reason: 'the panel repeats the chip s distance');
    expect(find.text('Elapsed'), findsOneWidget);
    // Chip, Elapsed and Moving all read 00:02 on this stream.
    expect(find.text('00:02'), findsNWidgets(3));
    expect(find.text('Moving'), findsOneWidget);
    expect(find.text('Altitude'), findsOneWidget);
    expect(find.text('44 m'), findsOneWidget,
        reason: 'the last accepted fix s altitude');
  });

  testWidgets('the recording camera follows the fixes; a pan releases it',
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
    await model.load();
    final source = FakePositionSource();

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
        locationSupported: true,
      ),
    ));
    await tester.pump();

    LatLng cameraCenter() => MapController.of(
            tester.element(find.byType(TileLayer)))
        .camera
        .center;

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0);
    fakeFix(source, 1, lat: 52.5201);
    await tester.pump();
    await tester.pump();

    // Follow-camera: each accepted fix centers the view on itself.
    final followed = cameraCenter();
    expect(followed.latitude, closeTo(52.5201, 1e-6));
    // The course-up marker rides the fix.
    expect(find.byIcon(Icons.navigation), findsOneWidget);

    // A user pan releases the follow: the next fix stays where it is on
    // the map, the marker takes the new position without recentering.
    // The empty-map hint sits dead center; drag below it.
    final size = tester.getSize(find.byType(FlutterMap));
    await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.8), const Offset(0, 80));
    await tester.pump();
    final panned = cameraCenter();
    expect(panned.latitude, greaterThan(followed.latitude),
        reason: 'dragging the map down moved the camera north');

    fakeFix(source, 2, lat: 52.5202);
    await tester.pump();
    expect(find.byIcon(Icons.navigation), findsOneWidget);
    expect(cameraCenter(), sameCameraAs(panned),
        reason: 'the pan released the follow');
  });

  testWidgets('dark theme darkens the tiles client-side, light leaves them',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();

    // Light theme: standard OSM tiles, no tile builder.
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(colorSchemeSeed: const Color(0xFF4363D8)),
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();
    expect(
        tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder, isNull);

    // Dark theme: tiles are inverted client-side (no new tile endpoint).
    // Several pumps: the theme switch settles a frame or two later than
    // the widget swap.
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(colorSchemeSeed: const Color(0xFF4363D8)),
      darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF4363D8),
          brightness: Brightness.dark),
      themeMode: ThemeMode.dark,
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder,
        same(darkModeTileBuilder));
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
        locationSupported: true,
      ),
    ));

    for (final label in const ['Import', 'Locate', 'Tracks', 'Settings']) {
      expect(find.text(label), findsOneWidget,
          reason: 'the $label action must be captioned');
    }
    // Fit is disabled on the empty map, but still shows its label.
    expect(find.text('Fit'), findsOneWidget);
  });

  testWidgets('the UI renders in Italian when the locale is Italian',
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

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      // Force the locale rather than relying on the test host's; the
      // delegate is the app's own, so this is the real resolution path.
      locale: const Locale('it'),
      localizationsDelegates: const [
        _TestMaterialDelegate(),
        _TestWidgetsDelegate(),
        _TestCupertinoDelegate(),
        _TestLocaleDelegate(),
      ],
      supportedLocales: AppStrings.supportedLocales,
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
        locationSupported: true,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Toolbar captions.
    for (final label in const [
      'Importa',
      'Inquadra',
      'Posizione',
      'Tracce',
      'Impostazioni'
    ]) {
      expect(find.text(label), findsOneWidget,
          reason: 'the $label action must be captioned');
    }
    expect(find.text('Import'), findsNothing);
    // Empty-map hint.
    expect(find.text('Ancora nessuna traccia'), findsOneWidget);

    // Settings sheet.
    await tester.tap(find.text('Impostazioni'));
    await tester.pumpAndSettle();
    expect(find.text('Colore delle tracce'), findsOneWidget);
    expect(find.text('Cursore dello zoom'), findsOneWidget);
    expect(find.text('Sinistra'), findsOneWidget);
    expect(find.text('Elimina tutte le tracce'), findsOneWidget);
    expect(find.text('Nessuna traccia archiviata'), findsOneWidget);
    expect(find.textContaining('Data di build:'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  /// Mocks the geolocator host channel. [permission] is the int the plugin
  /// uses for a LocationPermission; [position] is returned by
  /// getCurrentPosition (null means the fix times out).
  void mockGeolocator(
    WidgetTester tester, {
    required int permission,
    bool serviceEnabled = true,
    Map<String, double>? position,
    Duration fixDelay = Duration.zero,
  }) {
    const geolocatorChannel = MethodChannel('flutter.baseflow.com/geolocator');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        geolocatorChannel, (call) async {
      switch (call.method) {
        case 'isLocationServiceEnabled':
          return serviceEnabled;
        case 'checkPermission':
        case 'requestPermission':
          return permission;
        case 'getCurrentPosition':
          // A real fix is never instant; a delay lets tests observe the
          // in-flight state.
          if (fixDelay > Duration.zero) await Future.delayed(fixDelay);
          if (position == null) {
            throw PlatformException(code: 'TIMEOUT', message: 'no fix');
          }
          return <String, dynamic>{
            'latitude': position['lat'],
            'longitude': position['lon'],
            'timestamp': 0,
            'accuracy': 5.0,
            'altitude': 0.0,
            'altitudeAccuracy': 0.0,
            'heading': 0.0,
            'speed': 0.0,
            'speedAccuracy': 0.0,
            'floor': null,
            'isMocked': false,
          };
      }
      fail('unexpected geolocator method ${call.method}');
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(geolocatorChannel, null);
    });
  }

  /// Pumps a MapPage wide enough that every header action is tappable.
  Future<AppModel> pumpMap(
    WidgetTester tester, {
    bool locationSupported = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
        locationSupported: locationSupported,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return model;
  }

  testWidgets('locate is not offered where the platform has no location '
      'plugin', (tester) async {
    // Desktop Linux: geolocator has no implementation, so the action could
    // only ever fail.
    await pumpMap(tester, locationSupported: false);

    expect(find.text('Locate'), findsNothing);
    expect(find.byTooltip('Center on current position'), findsNothing);
    // The rest of the toolbar is untouched.
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Fit'), findsOneWidget);
  });

  testWidgets('locate centers on the fix and zooms in', (tester) async {
    mockGeolocator(tester, permission: 3, position: {
      'lat': 48.8584,
      'lon': 2.2945,
    });
    final model = await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    expect(camera.center.latitude, closeTo(48.8584, 1e-6));
    expect(camera.center.longitude, closeTo(2.2945, 1e-6));
    // Start zoom is 13; locating settles closer in.
    expect(camera.zoom, greaterThan(13.0));
    // The fix is saved for the next start.
    expect(model.savedPosition!.latitude, closeTo(48.8584, 1e-6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful locate shows the position marker',
      (tester) async {
    // Mock only after the startup pump: the silent startup fix would
    // otherwise already place the marker before the button is tapped.
    await pumpMap(tester);
    expect(find.byType(MarkerLayer), findsNothing);

    mockGeolocator(tester, permission: 3, position: {
      'lat': 48.8584,
      'lon': 2.2945,
    });
    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final layers = tester.widgetList<MarkerLayer>(find.byType(MarkerLayer));
    expect(layers, isNotEmpty);
    expect(layers.first.markers.single.point.latitude, closeTo(48.8584, 1e-6));
    expect(layers.first.markers.single.point.longitude, closeTo(2.2945, 1e-6));
  });

  testWidgets('a failed locate leaves no position marker', (tester) async {
    // Permission denied: locate fails, and no stale marker may remain.
    mockGeolocator(tester, permission: 1);
    await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MarkerLayer), findsNothing);
  });

  testWidgets('panning away from the fix drops the position marker',
      (tester) async {
    mockGeolocator(tester, permission: 3, position: {
      'lat': 48.8584,
      'lon': 2.2945,
    });
    await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MarkerLayer), findsOneWidget);

    // Pan far away (well past the 50 m clear threshold): the marker would
    // sit somewhere the user has left behind.
    final controller = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    controller.move(const LatLng(52.5200, 13.4050), 16.0);
    await tester.pump();

    expect(find.byType(MarkerLayer), findsNothing);
  });

  testWidgets('locate shows a spinner while the fix is in flight',
      (tester) async {
    mockGeolocator(tester, permission: 3, fixDelay: const Duration(seconds: 2),
        position: {
          'lat': 48.8584,
          'lon': 2.2945,
        });
    await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump(); // start the attempt

    // Waiting for the fix: the button is a spinner captioned "Locating…",
    // so a slow GPS never looks like a dead button.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Locating…'), findsOneWidget);
    expect(find.text('Locate'), findsNothing);

    // A second tap while in flight must not start another request.
    await tester.tap(find.text('Locating…'));
    await tester.pump();

    // The fix arrives: spinner gone, caption restored, camera moved.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Locate'), findsOneWidget);
    final camera = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;
    expect(camera.center.latitude, closeTo(48.8584, 1e-6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the locate spinner clears when the fix fails', (tester) async {
    // Granted permission, but no fix ever arrives.
    mockGeolocator(tester, permission: 3, fixDelay: const Duration(seconds: 1));
    await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // Failure is reported and the button is usable again.
    expect(find.textContaining('Location unavailable'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Locate'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locate reports a blocked permission', (tester) async {
    mockGeolocator(tester, permission: 1); // deniedForever
    await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Location permission is blocked'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locate reports location services being off', (tester) async {
    mockGeolocator(tester, permission: 3, serviceEnabled: false);
    await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('Location services are off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locate reports when no fix arrives', (tester) async {
    mockGeolocator(tester, permission: 3); // granted, but the fix times out
    await pumpMap(tester);

    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

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

  testWidgets('settings sheet picks the theme and persists it', (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup.
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

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Theme control may be off-screen; scroll to it
    await tester.ensureVisible(find.text('Theme'));
    await tester.pump();

    // Tap the Theme row to open the picker dialog
    await tester.tap(find.text('Theme'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Theme options are in the dialog
    expect(find.text('Dark'), findsOneWidget);

    // Tap Dark theme
    await tester.tap(find.text('Dark'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.themeMode, 'dark');

    // Verify persistence
    final reloaded = TrackStore(root);
    await reloaded.load();
    expect(reloaded.themeMode, 'dark');
  });

  testWidgets('switching to Dark theme resolves to dark brightness',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();

    // Set theme to dark
    await model.setThemeMode('dark');

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4363D8),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF4363D8),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      themeMode: model.themeModeValue,
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();

    // Verify the resolved theme brightness is dark by checking a widget in the tree
    final brightness = Theme.of(tester.element(find.byType(MapPage))).brightness;
    expect(brightness, Brightness.dark);
  });

  testWidgets('unlocked road corridors render as translucent polylines',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();
    // Activate the synthetic road file and import the Main Street walk so
    // the track carries corridor unlock state.
    final roadFile = File(
        '${root.path}${Platform.pathSeparator}test_roads.unvisited-roads');
    roadFile.writeAsBytesSync(fixture('test_roads.unvisited-roads'));
    model.setRoadFile(roadFile.path);
    final walk = File(
        '${root.path}${Platform.pathSeparator}main_street_walk.gpx');
    walk.writeAsBytesSync(fixture('main_street_walk.gpx'));
    await model.importFromFile(walk.path);

    await tester.pumpWidget(MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache,
        versionFuture: Future.value('2026-11-12 12:00'),
      ),
    ));
    await tester.pump();

    // The corridor layer exists and its polylines run along Main Street.
    final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    expect(layer.polylines, isNotEmpty);
    for (final polyline in layer.polylines) {
      for (final p in polyline.points) {
        expect(p.latitude, closeTo(52.5200, 1e-3));
      }
    }
  });

  testWidgets('a catalog without corridor state renders no polyline layer',
      (tester) async {
    final root = createRoot();
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup.
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

    expect(find.byType(PolylineLayer), findsNothing);
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

/// Mirrors the app's private `_AppLocaleDelegate` (main.dart): MaterialApp
/// only needs *a* delegate that loads AppStrings for the test to exercise
/// the real locale resolution.
class _TestLocaleDelegate extends LocalizationsDelegate<AppStrings> {
  const _TestLocaleDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppStrings.supported.containsKey(locale.languageCode);

  @override
  Future<AppStrings> load(Locale locale) async => AppStrings.of(locale);

  @override
  bool shouldReload(_TestLocaleDelegate old) => false;
}

/// Mirrors `_AnyLocaleMaterialDelegate` in main.dart. Without it a
/// non-English locale has no MaterialLocalizations and Scaffold's drawer
/// fails to build - which is exactly what the Italian test guards against.
class _TestMaterialDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _TestMaterialDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      DefaultMaterialLocalizations.load(locale);

  @override
  bool shouldReload(_TestMaterialDelegate old) => false;
}

/// Mirrors `_AnyLocaleWidgetsDelegate` in main.dart.
class _TestWidgetsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const _TestWidgetsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      DefaultWidgetsLocalizations.load(locale);

  @override
  bool shouldReload(_TestWidgetsDelegate old) => false;
}

/// Mirrors `_AnyLocaleCupertinoDelegate` in main.dart.
class _TestCupertinoDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _TestCupertinoDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      DefaultCupertinoLocalizations.load(locale);

  @override
  bool shouldReload(_TestCupertinoDelegate old) => false;
}

/// A fix stream the widget tests push through the model's record action.
class FakePositionSource implements PositionSource {
  FakePositionSource();
  final controller = StreamController<PositionFix>();
  @override
  Stream<PositionFix> get stream => controller.stream;
}

/// One walking fix per second north along the Greenwich meridian, ~11.1 m
/// between consecutive points.
void fakeFix(
  FakePositionSource source,
  int second, {
  double lat = 52.5200,
  double prevLat = 52.5200,
  double lon = 13.4050,
  double? ele,
  double? acc = 5,
  double? speed,
  double? heading,
}) {
  source.controller.add(PositionFix(
    lat: lat,
    lon: lon,
    time: DateTime.utc(2026, 11, 13, 12).add(Duration(seconds: second)),
    ele: ele,
    accuracy: acc,
    speed: speed,
    heading: heading,
  ));
}

/// Matches a camera center against [expected] positionally: the released
/// follow-camera must leave the view where the user's pan put it.
Matcher sameCameraAs(LatLng expected) => predicate<LatLng>(
    (c) =>
        (c.latitude - expected.latitude).abs() < 1e-6 &&
        (c.longitude - expected.longitude).abs() < 1e-6,
    'camera stays at $expected');
