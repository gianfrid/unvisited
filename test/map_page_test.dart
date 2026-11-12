import 'dart:io';

import 'package:flutter/material.dart';
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

  testWidgets('track drawer footer shows the build version', (tester) async {
    final root = createRoot();
    final model = AppModel(TrackStore(root));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        endDrawer: TrackDrawer(
          model: model,
          versionFuture: Future.value('2026-11-12 17:41'),
        ),
      ),
    ));
    tester.state<ScaffoldState>(find.byType(Scaffold)).openEndDrawer();
    await tester.pumpAndSettle();

    expect(find.text('2026-11-12 17:41'), findsOneWidget);
  });
}
