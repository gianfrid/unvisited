import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:unvisited/import/kmz_parser.dart';
import 'package:unvisited/import/track_importer.dart';
import 'package:unvisited/import/track_parser.dart';
import 'package:unvisited/import/tcx_parser.dart';
import 'package:unvisited/import/gpx_parser.dart';
import 'package:unvisited/import/fit_parser.dart';
import 'package:unvisited/models/track.dart';
import 'package:unvisited/recording/position_source.dart'
    show PositionFix, PositionSource;
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';
import 'package:unvisited/ui/map_page.dart';

/// Loads a checked-in fixture as raw bytes.
List<int> fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// Small track parsers for edge tests.
final allParsers = <TrackParser>[
  GpxParser(),
  FitParser(),
  KmzParser(),
  TcxParser(),
];

TrackData parseFixture(String name, {String? filename}) =>
    TrackImporter().import(fixture(name), filename: filename);

/// The build time every widget test injects into the page, so no git
/// process spawns from a test and the About card is deterministic.
const testBuildTime = '2026-11-12 12:00';

/// A fresh store root, deleted best-effort when the test ends: a failure
/// to clean a temp dir must not fail the test.
Directory createRoot() {
  final root = Directory.systemTemp.createTempSync('unvisited-store');
  addTearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on Exception {
      // Best-effort cleanup.
    }
  });
  return root;
}

/// The map's tile-cache directory for one test (see [createRoot]).
Directory createCache() {
  final cache = Directory.systemTemp.createTempSync('unvisited-cache');
  addTearDown(() {
    try {
      cache.deleteSync(recursive: true);
    } on Exception {
      // Best-effort cleanup.
    }
  });
  return cache;
}

/// A loaded model on a fresh store root (or [root], when the test wants
/// to reach under it — salvage, delete, file assertions).
Future<AppModel> createModel([Directory? root]) async {
  final model = AppModel(TrackStore(root ?? createRoot()));
  await model.load();
  return model;
}

/// Pumps the map page the way the widget tests display it: full
/// MaterialApp in the fixed build time, the standard cache and location
/// support unless a test says otherwise.
Future<void> pumpMapPage(
  WidgetTester tester, {
  required AppModel model,
  Directory? cache,
  bool locationSupported = true,
  String buildTime = testBuildTime,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MapPage(
        model: model,
        cacheDir: cache ?? createCache(),
        versionFuture: Future.value(buildTime),
        locationSupported: locationSupported,
      ),
    ),
  );
  await tester.pump();
}

/// A fix stream the recording tests push through at will.
class FakePositionSource implements PositionSource {
  FakePositionSource();
  final controller = StreamController<PositionFix>();

  @override
  Stream<PositionFix> get stream => controller.stream;
}

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
    geolocatorChannel,
    (call) async {
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
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      geolocatorChannel,
      null,
    );
  });
}
