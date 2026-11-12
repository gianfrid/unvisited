import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';
import 'package:unvisited/ui/map_page.dart';

void main() {
  testWidgets('MapPage builds its tile layer without crashing', (tester) async {
    final root = Directory.systemTemp.createTempSync('unvisited-store');
    final cache = Directory.systemTemp.createTempSync('unvisited-cache');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
      try {
        cache.deleteSync(recursive: true);
      } on Exception {
        // See above.
      }
    });
    final model = AppModel(TrackStore(root));
    await model.load();

    await tester.pumpWidget(
      MaterialApp(home: MapPage(model: model, cacheDir: cache)),
    );
    await tester.pump();

    // A const tile provider headers map is unmodifiable; TileLayer's
    // constructor inserts a default User-Agent into it and throws.
    expect(tester.takeException(), isNull);
    expect(find.byType(FlutterMap), findsOneWidget);
  });
}
