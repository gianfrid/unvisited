import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerScrollEvent;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:file_picker/file_picker.dart'
    show
        FilePickerPlatform,
        FilePickerStatus,
        LinuxOptions,
        MethodChannelFilePicker,
        WebOptions,
        WindowsOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/l10n/app_strings.dart';
import 'package:unvisited/photos/photo_source.dart' show PhotoCaptureSucceeded;
import 'package:unvisited/ui/photo_preview.dart';
import 'package:unvisited/recording/position_source.dart' show PositionFix;
import 'package:unvisited/recording/recording_session.dart' show RecordingState;
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/tile_source.dart';
import 'package:unvisited/ui/app_model.dart';
import 'package:unvisited/ui/fog_of_war.dart';
import 'package:unvisited/ui/ink_stroke.dart' show inkWidthMeters;
import 'package:unvisited/ui/map_actions.dart';
import 'package:unvisited/ui/map_page.dart';
import 'package:unvisited/ui/recording_dashboard.dart';
import 'package:unvisited/ui/road_coverage_chip.dart';
import 'package:unvisited/ui/track_colors.dart';

import 'helpers.dart';

/// A save-only FilePickerPlatform: the "save dialog" writes the handed
/// bytes to [target] and answers with its file URI (null = cancelled).
/// Just enough glue for the export-menu wiring tests.
class FakeSavePicker extends FilePickerPlatform {
  FakeSavePicker(this.target);

  final String? target;

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
    final path = target;
    if (path == null) return null;
    File(path).writeAsBytesSync(bytes);
    return Uri.file(path);
  }
}

void main() {
  testWidgets('MapPage builds its tile layer without crashing', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
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

  testWidgets('switching to the cycle layer swaps the tile source', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
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

  testWidgets('record action starts a session the chip shows and stops it', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();
    // The Record button is gated on a real fix (slice 6): grant the mock
    // a position so the startup poll opens the gate.
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
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

    // The slot turns into the pause and Stop rides above it the whole
    // session; the chip shows the live stats — the pulsing dot and the
    // meters walked (the engine's haversine sum).
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(
      find.byIcon(Icons.fiber_manual_record),
      findsOneWidget,
      reason: 'the pulse dot on the chip',
    );
    expect(find.text('11 m'), findsOneWidget);

    // The stop's import runs behind a real-file read that FakeAsync's
    // zone never drains (a flush queued inside it never settles), so the
    // widget-land assertions end here; the stop-through-import chain and
    // the import round-trip are covered by the model-level tests.
    expect(model.recording, isNotNull);
  });

  testWidgets('record mode trims the header and shows the speed readout', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    // Idle: the full header, no dashboard, no speed readout.
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Locate'), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-speed')), findsNothing);

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0, speed: 3.0);
    fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201, speed: 3.0);
    await tester.pump();
    await tester.pump();

    // Recording: Import and Fit are hidden (they fight the dashboard for
    // space and attention) and Locate takes a break too — the session's
    // follow-camera is armed on the fresh fix, so the button would be
    // redundant; it returns when a pan releases the follow. The slot reads
    // Pause, with Stop above it the whole session. The live speed is the
    // primary readout, big in the top bar's center, from the engine's fix
    // speed.
    expect(find.text('Import'), findsNothing);
    expect(find.text('Locate'), findsNothing);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    final speedCard = find.byKey(const ValueKey('recording-speed'));
    expect(speedCard, findsOneWidget);
    // The speed readout rides in the top bar's pill: the top half, above
    // the whole bottom column.
    final mapRect = tester.getRect(find.byType(FlutterMap));
    final speedRect = tester.getRect(speedCard);
    final pauseRect = tester.getRect(find.byTooltip('Pause'));
    expect(
      speedRect.top,
      lessThan(mapRect.height * 0.5),
      reason: 'the speed readout sits in the top bar',
    );
    expect(
      speedRect.bottom,
      lessThan(pauseRect.top),
      reason: 'the speed readout never reaches the bottom column',
    );
    expect(find.text('10.8'), findsOneWidget);

    // The stop's import again never settles in the fake-async zone, so
    // it runs unawaited: stopRecording clears the session and notifies
    // synchronously, which is all the UI restore needs.
    model.stopRecording();
    await tester.pump();

    // All restored: the header is whole again and the readout is gone.
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Locate'), findsOneWidget);
    expect(find.text('Pause'), findsNothing);
    expect(find.byKey(const ValueKey('recording-speed')), findsNothing);
  });

  testWidgets('the pause action flips to resume and back', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0, prevLat: 52.5200, lat: 52.5201);
    await tester.pump();
    await tester.pump();
    expect(find.text('Pause'), findsOneWidget);

    // Pausing flips the action to Resume; the session's pause semantics
    // (closed trkseg, silent fixes) are the engine's, covered upstream —
    // here the UI wiring is what is under test. A paused session's dropped
    // fix still cannot change distance.
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(model.recording!.state, RecordingState.paused);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Pause'), findsNothing);
    expect(
      find.text('Stop'),
      findsOneWidget,
      reason: 'stop appears before the resume slot once paused',
    );
    final distance = model.recording!.distanceMeters;

    fakeFix(source, 5, prevLat: 52.5210, lat: 52.5220);
    await tester.pump();
    expect(model.recording!.distanceMeters, distance);

    await tester.tap(find.byTooltip('Resume'));
    await tester.pump();
    expect(model.recording!.state, RecordingState.recording);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
    expect(
      find.text('Stop'),
      findsOneWidget,
      reason: 'stop stays in the stack in every session state',
    );

    model.stopRecording();
    await tester.pump();
  });

  testWidgets('stop asks for the track name; cancelling keeps recording', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0);
    fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201);
    await tester.pump();
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();

    // The dialog: a name field seeded with the current date-time
    // timestamp (`YYYY-MM-DD HH:mm`, the staged name's format).
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, matches(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'));
    expect(find.text('Stop recording'), findsOneWidget);
    expect(find.text('Track name'), findsOneWidget);

    // Cancel: the dialog closes and the session keeps recording — the
    // stacked Stop action is still there, so the stop stays reachable.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(model.recording, isNotNull);
    expect(find.byTooltip('Stop'), findsOneWidget);

    // Confirm finalizes: the session clears now (the import runs behind
    // a real-file read that FakeAsync's zone never drains — covered at
    // the model level, named and nameless).
    await tester.tap(find.byTooltip('Stop'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Bike home');
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Save'),
      ),
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(model.recording, isNull);
  });

  testWidgets(
    'stop offers Discard behind a confirmation; declined keeps recording',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201);
      await tester.pump();
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop'));
      await tester.pump();

      // The stop dialog offers Save and a red Discard. Discard opens the
      // confirmation rather than acting on its own — it destroys the whole
      // staged track, an irreversible act.
      expect(find.byKey(const ValueKey('stop-discard')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('stop-discard')));
      await tester.pump();

      // The confirm dialog: a declined Discard keeps the session recording.
      expect(find.text('Discard this recording?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(model.recording, isNotNull);
      expect(find.byType(AlertDialog), findsNothing);

      // The second attempt discards: the session ends, no track appears.
      // (The staged-file deletion settles behind a real-file read that
      // FakeAsync's zone never drains — see the stop test above; the model
      // test asserts the file is gone and salvage finds nothing.)
      await tester.tap(find.byTooltip('Stop'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('stop-discard')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('stop-discard-confirm')));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(model.recording, isNull);
      expect(model.tracks, isEmpty);
    },
  );

  testWidgets('a salvaged staged recording announces itself at startup', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    // The kill-mid-session leftover under the app root: complete points,
    // an open segment, no closers (what the stage writer guarantees).
    final dir = Directory('${root.path}${Platform.pathSeparator}recording')
      ..createSync(recursive: true);
    final sink = StringBuffer();
    sink.write('<?xml version="1.0" encoding="UTF-8"?>\n');
    sink.write(
      '<gpx version="1.1" creator="unvisited" '
      'xmlns="http://www.topografix.com/GPX/1/1">\n',
    );
    sink.write('<trk><name>Recovered walk</name>\n<trkseg>\n');
    for (final i in [0, 1]) {
      final t = DateTime.utc(2026, 11, 13, 12, 0, i);
      sink.write(
        '<trkpt lat="52.520${i}00" lon="13.405000">\n'
        '<ele>42.00</ele>\n<time>${t.toIso8601String()}</time>\n</trkpt>\n',
      );
    }
    File('${dir.path}${Platform.pathSeparator}1763040000000.gpx')
        .writeAsStringSync(sink.toString());

    final model = AppModel(TrackStore(root));
    // The salvage read is real dart:io IO — it never settles inside the
    // fake-async test zone, so the load runs in runAsync.
    await tester.runAsync(() => model.load());

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Recovered walk'), findsOneWidget);
  });

  testWidgets(
    'the chip has no screen-lock toggle; the keepScreenOn setting drives the latch',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      // The latch calls ride the host channel; record them.
      final latchCalls = <bool>[];
      const host = MethodChannel('unvisited/host');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(host, (
        call,
      ) async {
        if (call.method == 'keepScreenOn') {
          latchCalls.add(call.arguments as bool);
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          host,
          null,
        ),
      );

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      // No session: no chip, and no lock icon anywhere.
      expect(find.byIcon(Icons.screen_lock_portrait), findsNothing);

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      fakeFix(source, 1, lat: 52.5201);
      await tester.pump();
      await tester.pump();

      // The chip is there, the lock toggle is gone; the latch went on with
      // the session (keepScreenOn defaults to on).
      expect(find.byKey(const ValueKey('recording-chip')), findsOneWidget);
      expect(find.byIcon(Icons.screen_lock_portrait), findsNothing);
      expect(latchCalls, [true]);

      // The setting applies immediately, mid-session: toggling it off
      // clears the latch at once (the model change re-applies it), and back
      // on re-arms it.
      await model.setKeepScreenOn(false);
      await tester.pump();
      expect(latchCalls, [true, false]);
      await model.setKeepScreenOn(true);
      await tester.pump();
      expect(latchCalls, [true, false, true]);

      // Stop ends the session: the latch clears (the stop's import never
      // settles in the fake-async zone, but the synchronous clear and
      // notification are all the latch needs).
      model.stopRecording();
      await tester.pump();
      expect(latchCalls, [true, false, true, false]);
    },
  );

  testWidgets('the dashboard expands into the stats panel with live numbers', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
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

    // The tap rides the pulse dot's InkWell.
    await tester.tap(find.byIcon(Icons.fiber_manual_record));
    await tester.pump();

    expect(find.byKey(const ValueKey('stats-panel')), findsOneWidget);
    // The live speed is the primary readout — the big one in the top
    // bar's center, showing the fix's own 1 m/s — no longer a panel row
    // or a passenger in the chip row. The panel labels the averages,
    // distance, both durations and the altitude the fix reported.
    expect(find.text('Speed'), findsNothing);
    expect(find.text('3.6'), findsOneWidget);
    expect(find.text('Avg speed'), findsOneWidget);
    expect(find.text('40.0 km/h'), findsOneWidget);
    expect(find.text('Distance'), findsOneWidget);
    expect(
      find.text('22 m'),
      findsNWidgets(2),
      reason: 'the panel repeats the chip s distance',
    );
    expect(find.text('Elapsed'), findsOneWidget);
    // Chip, Elapsed and Moving all read 00:02 on this stream.
    expect(find.text('00:02'), findsNWidgets(3));
    expect(find.text('Moving'), findsOneWidget);
    expect(find.text('Altitude'), findsOneWidget);
    expect(
      find.text('44 m'),
      findsOneWidget,
      reason: 'the last accepted fix s altitude',
    );
  });

  testWidgets('the recording camera follows the fixes; a pan releases it', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    LatLng cameraCenter() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera.center;

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0);
    fakeFix(source, 1, lat: 52.5201);
    await pumpGlide(tester);

    // Follow-camera: each accepted fix centers the view on itself, framed
    // slightly below screen center (north-up: the center sits north of the
    // fix).
    final followed = cameraCenter();
    expect(followed.latitude, greaterThan(52.5201));
    expect(followed.latitude, lessThan(52.5201 + 1e-3));
    // The course-up marker rides the fix.
    expect(find.byIcon(Icons.navigation), findsOneWidget);

    // A deliberate two-finger pan releases the follow (one-finger drags
    // are inert while the follow is armed): the next fix stays where the
    // pan put it on the map, the marker takes the new position without
    // recentering. From the map's free middle — the bottom column holds
    // the dashboard and the action stack while recording.
    final size = tester.getSize(find.byType(FlutterMap));
    await twoFingerPan(
      tester,
      start: Offset(size.width / 2, size.height * 0.4),
    );
    final panned = cameraCenter();
    expect(
      panned.latitude,
      greaterThan(followed.latitude),
      reason: 'dragging the map down moved the camera north',
    );

    fakeFix(source, 2, lat: 52.5202);
    await tester.pump();
    expect(find.byIcon(Icons.navigation), findsOneWidget);
    expect(
      cameraCenter(),
      sameCameraAs(panned),
      reason: 'the pan released the follow',
    );
  });

  testWidgets('a fix arriving mid-glide steps the camera gently, not a snap', (
    tester,
  ) async {
    // Regression (field video 2026-11-19): resetting the glide clock on a
    // still-running ticker made one frame read the ticker's whole age as
    // its dt — the camera jumped most of the remaining distance in a
    // single frame whenever a fix arrived mid-ease, which reads as a
    // "laggy" snap-glide-snap camera.
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    LatLng cameraCenter() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera.center;

    await model.startRecording(source: source, permissionGate: false);
    // The first fix glides in and settles — its ticker stops.
    fakeFix(source, 0, lat: 52.5200);
    await pumpGlide(tester);
    // A second fix, three frames of easing in: far from settled, so its
    // glide ticker is still running when the third fix lands.
    fakeFix(source, 1, lat: 52.5201);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final before = cameraCenter();
    // The third fix re-targets the *running* ticker: one 16 ms frame must
    // advance a fraction of the remaining distance, not most of it.
    fakeFix(source, 2, lat: 52.5202);
    await tester.pump(const Duration(milliseconds: 16));
    final stepped = cameraCenter();
    await pumpGlide(tester);
    final settled = cameraCenter();
    final step = (stepped.latitude - before.latitude).abs();
    final remaining = (settled.latitude - before.latitude).abs();
    expect(remaining, greaterThan(0), reason: 'the follow moved the camera');
    expect(
      step,
      lessThan(remaining * 0.15),
      reason: 'a reused glide ticker eased one 16 ms frame (k~0.045), '
          'not a whole-age dt jump (~0.38 on the old clock reset)',
    );
  });

  testWidgets(
    'a zoom button tapped mid-glide holds; the glide does not ease it back',
    (tester) async {
      // Regression (field report: "the zoom while recording is bouncing
      // badly"): a zoom-only move through the controller was adopted as
      // the ride's zoom, but the glide still in flight kept easing toward
      // its stale target — the tap was undone for up to a fix interval,
      // then sprang back the other way once the next fix adopted it, ~1.3
      // zoom levels of visible bounce per tap.
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      double zoom() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera.zoom;

      await model.startRecording(source: source, permissionGate: false);
      // The opening ride: the first fix takes the camera from the start
      // zoom (13) toward the follow floor (17), still gliding a second
      // later — the window a rider's zoom tap lands in.
      fakeFix(source, 0);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final before = zoom();
      expect(
        before,
        lessThan(17.0),
        reason: 'the opening glide is still below the floor',
      );

      await tester.tap(find.byKey(const ValueKey('zoom-out-button')));
      await tester.pump();
      final tapped = zoom();
      expect(tapped, closeTo(before - 1, 1e-9));

      // The glide keeps running after the tap: it must stop changing the
      // zoom, not ease back toward the stale target.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          zoom(),
          closeTo(tapped, 1e-9),
          reason: 'no glide frame may walk the hand s zoom back',
        );
      }

      // The next fix adopts the hand's zoom too — no spring back to the
      // floor once the ride re-targets.
      fakeFix(source, 1);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        zoom(),
        closeTo(tapped, 1e-9),
        reason: 'the ride holds the zoom the hand set',
      );
    },
  );

  testWidgets(
    'a wheel zoom-out survives the follow re-arm (Locate) — the hand s zoom holds',
    (tester) async {
      // TODO.md #1 regression: the wheel is a camera-moving hand, so it
      // released the follow but never adopted its zoom (only the pill's
      // center-static move was adopted) — on the Locate re-arm the next
      // fix re-floored the ride to 17 and walked the hand's zoom back up.
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      await pumpGlide(tester);
      expect(camera().zoom, greaterThanOrEqualTo(17.0));

      // Ten wheel notches out (flutter_map: newZoom = zoom - dy * 0.005)
      // — the hand releases the follow at a much lower zoom.
      final center = tester.getCenter(find.byType(FlutterMap));
      for (var i = 0; i < 10; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.mouse,
            position: center,
            scrollDelta: const Offset(0, 200),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      final handZoom = camera().zoom;
      expect(
        handZoom,
        lessThan(12.0),
        reason: 'the wheel zoomed far out and released the follow',
      );

      // Locate is the way back while recording: re-arm on the session's
      // fix at the user's zoom; the next fix must keep the hand's zoom,
      // not re-floor to 17.
      await tester.tap(find.byTooltip('Center on current position'));
      await tester.pump();
      fakeFix(source, 1);
      await pumpGlide(tester);
      expect(
        camera().zoom,
        closeTo(handZoom, 0.05),
        reason: 'the re-armed follow rides the hand s zoom, not the floor',
      );
    },
  );

  test('nearestEquivalentRotation picks the nearest mod-360 equivalent', () {
    // Crossing the 0/360 boundary: 10 applied against 350, and 350
    // applied against 10, rotate through the short arc.
    expect(nearestEquivalentRotation(10.0, 350.0), closeTo(370.0, 1e-9));
    expect(nearestEquivalentRotation(350.0, 10.0), closeTo(-10.0, 1e-9));
    // An already-normalized pair is a no-op; a quarter away rotates a
    // quarter of the way.
    expect(nearestEquivalentRotation(90.0, 90.0), closeTo(90.0, 1e-9));
    expect(nearestEquivalentRotation(45.0, 315.0), closeTo(405.0, 1e-9));
  });

  testWidgets(
    'while recording the camera rotates course-up; a pan releases it',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      // Course-up is opt-in: this test exercises the 'on' setting.
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;
      double markerAngle() {
        final m = tester
            .widget<Transform>(
              find.byKey(const ValueKey('recording-marker-rotate')),
            )
            .transform;
        return math.atan2(m.entry(1, 0), m.entry(0, 0));
      }

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, heading: 90);
      fakeFix(source, 1, lat: 52.5201, heading: 90);
      // The rotation eases in over several fixes (exponential smoothing),
      // converging on the course.
      for (var i = 2; i < 16; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90);
      }
      // The glide eases the camera to the fix targets over ~1 s of frames.
      await pumpGlide(tester);

      // Course-up: the east-heading fixes rotate the camera to -90 (east
      // points screen-up; flutter_map rotation is clockwise-positive), and
      // the marker draws the course in map-content space — with the
      // camera riding the course, the nose nets to up on screen.
      expect(camera().rotation % 360, closeTo(270.0, 1.0));
      // The marker keeps a solid backdrop disc so it stays visible over
      // the live trace.
      expect(
        find.byKey(const ValueKey('recording-marker-disc')),
        findsOneWidget,
      );
      expect(markerAngle(), closeTo(math.pi / 2, 0.05));

      // A deliberate two-finger pan releases the follow — and the rotation
      // with it: the next fix re-centers nothing and leaves the rotation
      // where the pan put it. (One-finger drags are inert while the follow
      // is armed; from the free middle — the bottom column is occupied.)
      final size = tester.getSize(find.byType(FlutterMap));
      await twoFingerPan(
        tester,
        start: Offset(size.width / 2, size.height * 0.4),
      );
      final panned = camera().center;
      // Continue forward from the last fix (a backward jump would be
      // rejected by the speed-outlier filter).
      fakeFix(source, 16, lat: 52.5216 + 1e-4, heading: 180);
      await tester.pump();

      expect(
        camera().rotation % 360,
        closeTo(270.0, 1.0),
        reason: 'the pan released the rotation with the follow',
      );
      expect(
        camera().center,
        sameCameraAs(panned),
        reason: 'the pan released the follow',
      );
      // The released follow leaves the camera at -90 while the course
      // turns to 180: the marker draws the course itself in content
      // space — the map's content rotation composes with the camera, so
      // the nose still points along the course on screen.
      expect(markerAngle(), closeTo(math.pi, 0.05));
    },
  );

  testWidgets(
    'a fix below the speed gate holds the camera rotation but still centers',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      // One fix: the glide converges on the course (0 -> -90), not snapping.
      fakeFix(source, 0, heading: 90, speed: 5.0);
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 0.1));
      for (var i = 1; i < 16; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 5.0);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 1.0));

      // Slow fix with a different heading: the camera holds its rotation
      // (no standstill spin) but still centers on the fix. The fix moves
      // only ~5.5 m from the last one — a backward jump would be rejected
      // by the speed-outlier filter.
      fakeFix(source, 16, lat: 52.5216 + 0.00005, heading: 180, speed: 0.2);
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 1.0));
      // The camera frames the fix below screen center: with the camera
      // held at -90°, screen-up is geographic east, so the center sits
      // east of the fix.
      expect(camera().center.longitude, greaterThan(13.4050));
      expect(camera().center.latitude, closeTo(52.5216 + 0.00005, 1e-4));

      // Moving again: the rotation eases over to the new course. Continue
      // forward from the last accepted fix (i=16 at 52.5216 + 0.00005).
      for (var i = 17; i < 32; i++) {
        fakeFix(source, i, lat: 52.5216 + 0.00005 + (i - 16) * 1e-4,
            heading: 180, speed: 3.0);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(180.0, 1.0));
    },
  );

  testWidgets(
    'a pan releases the follow until the locate button is pressed again',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201, heading: 90, speed: 5.0);
      await tester.pump();
      await tester.pump();

      // A deliberate two-finger pan releases the follow (one-finger drags
      // are inert while it is armed): the next fix does not re-center.
      final size = tester.getSize(find.byType(FlutterMap));
      await twoFingerPan(
        tester,
        start: Offset(size.width / 2, size.height * 0.4),
      );
      final panned = camera().center;
      fakeFix(source, 1, lat: 52.5202, heading: 90, speed: 5.0);
      await tester.pump();
      expect(camera().center, sameCameraAs(panned));

      // No timed re-engage: well past any delay, the next fix still does
      // not re-center.
      await tester.pump(const Duration(seconds: 21));
      fakeFix(source, 2, lat: 52.5203, heading: 90, speed: 5.0);
      await tester.pump();
      expect(camera().center, sameCameraAs(panned));

      // The locate button is the way back: the tap re-centers on the
      // session's fix, and the follow re-arms — the next fix rides the
      // camera again.
      await tester.tap(find.byTooltip('Center on current position'));
      await tester.pump();
      expect(camera().center.latitude, closeTo(52.5203, 1e-6));
      fakeFix(source, 3, lat: 52.5204, heading: 90, speed: 5.0);
      await tester.pump();
      await tester.pump();
      expect(camera().center.latitude, closeTo(52.5204, 1e-3));
    },
  );

  testWidgets(
    'a plain tap on the map does not release the follow',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201, heading: 90, speed: 5.0);
      await tester.pump();
      await tester.pump();
      final followed = camera().center;

      // A stray tap (mount, pocket, glove) must not disengage the follow:
      // only a gesture that moves the map may release it. If the tap had
      // released it, the next fix would leave the camera exactly where it
      // was.
      final size = tester.getSize(find.byType(FlutterMap));
      await tester.tapAt(Offset(size.width / 2, size.height * 0.4));
      // Let flutter_map's double-tap detection timer run out.
      await tester.pump(const Duration(seconds: 1));
      fakeFix(source, 1, lat: 52.5202, heading: 90, speed: 5.0);
      await tester.pump();
      expect(
        camera().center,
        isNot(sameCameraAs(followed)),
        reason: 'the tap did not release the follow; the next fix re-centered',
      );
      expect(
        camera().center.latitude,
        closeTo(52.5202, 1e-3),
        reason: 'the follow re-centered on the new fix',
      );
    },
  );

  testWidgets(
    'while the follow is armed, a one-finger drag pans as a peek and returns on lift',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201);
      await pumpGlide(tester);
      final followed = camera().center;

      // The one-finger drag pans the map live — feedback, never a dead
      // map — read before the return glide can run its first frame.
      final size = tester.getSize(find.byType(FlutterMap));
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.4),
        const Offset(0, 80),
      );
      final peeked = camera().center;
      expect(
        peeked.latitude,
        greaterThan(followed.latitude),
        reason: 'the drag panned the map under the hand',
      );
      // The follow never disengaged — no release toast. The first
      // peek's return instead teaches the two-finger escape.
      expect(
        find.text('Camera free — long-press the map to re-center'),
        findsNothing,
        reason: 'the peek released nothing',
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Two fingers to pan the map freely'),
        findsOneWidget,
        reason: 'the first peek return teaches the two-finger escape',
      );

      // The lift is the return: the camera glides back to the fix's
      // framing, the follow armed all along.
      await pumpGlide(tester);
      expect(
        camera().center.latitude,
        greaterThan(52.5201),
        reason: 'the return frames the fix (center north of it)',
      );
      expect(
        camera().center.latitude,
        lessThan(52.5201 + 1e-3),
        reason: 'the return re-centered on the fix',
      );
      // And the follow still rides: the next fix moves the camera.
      fakeFix(source, 1, lat: 52.5202);
      await pumpGlide(tester);
      expect(
        camera().center.latitude,
        greaterThan(52.5202),
        reason: 'the follow still frames the new fix after the peek',
      );
    },
  );

  testWidgets(
    'a fix arriving mid-peek is held; the lift returns to the new fix',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201);
      await pumpGlide(tester);

      // The peeking hand holds the camera: finger down, dragged, kept
      // down.
      final size = tester.getSize(find.byType(FlutterMap));
      final gesture = await tester.startGesture(
        Offset(size.width / 2, size.height * 0.4),
      );
      await gesture.moveBy(const Offset(0, 80));
      final peeked = camera().center;

      // A fix arrives while the finger is still down: its target is
      // stored, never eased toward — nothing may pull against the hand.
      fakeFix(source, 1, lat: 52.5202);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        camera().center,
        sameCameraAs(peeked),
        reason: 'the held target never pulled the camera mid-peek',
      );

      // The lift returns to the NEW fix's framing, not the old one.
      await gesture.up();
      await pumpGlide(tester);
      expect(
        camera().center.latitude,
        greaterThan(52.5202),
        reason: 'the return frames the new fix (center north of it)',
      );
      expect(
        camera().center.latitude,
        lessThan(52.5202 + 1e-3),
        reason: 'the return re-centered on the new fix',
      );
    },
  );

  testWidgets(
    'the peek return teaches the two-finger escape once per session',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201);
      await pumpGlide(tester);
      final size = tester.getSize(find.byType(FlutterMap));

      // The first peek's return teaches.
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.4),
        const Offset(0, 80),
      );
      await pumpGlide(tester);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Two fingers to pan the map freely'),
        findsOneWidget,
        reason: 'the first peek return taught the escape',
      );

      // The teaching toast expires; the second peek's return must not
      // teach again — accidental brushes never nag.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Two fingers to pan the map freely'),
        findsNothing,
        reason: 'the toast expired',
      );
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.4),
        const Offset(0, 80),
      );
      await pumpGlide(tester);
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Two fingers to pan the map freely'),
        findsNothing,
        reason: 'the latch held: the second peek taught nothing',
      );
      // The follow rode both peeks and still frames the fix.
      expect(
        camera().center.latitude,
        greaterThan(52.5201),
        reason: 'the follow still frames the fix after two peeks',
      );
    },
  );

  testWidgets(
    'after a two-finger release, one-finger panning works again',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201);
      await pumpGlide(tester);

      // The deliberate two-finger pan releases the follow — and the lock
      // goes with it: the map is free again.
      final size = tester.getSize(find.byType(FlutterMap));
      await twoFingerPan(
        tester,
        start: Offset(size.width / 2, size.height * 0.4),
      );
      final panned = camera().center;

      // One finger pans freely now (the lock follows the armed state).
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.4),
        const Offset(0, 60),
      );
      await tester.pump();
      expect(
        camera().center.latitude,
        greaterThan(panned.latitude),
        reason: 'the one-finger drag moved the released camera',
      );

      // And the follow stays released: the next fix does not re-center.
      final moved = camera().center;
      fakeFix(source, 1, lat: 52.5202);
      await tester.pump();
      expect(
        camera().center,
        sameCameraAs(moved),
        reason: 'the follow stays released',
      );
    },
  );

  testWidgets(
    'a long-press re-arms a released follow and re-centers on the fix',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201);
      await pumpGlide(tester);

      // Release with a deliberate two-finger pan; the next fix must not
      // re-center.
      final size = tester.getSize(find.byType(FlutterMap));
      await twoFingerPan(
        tester,
        start: Offset(size.width / 2, size.height * 0.4),
      );
      final panned = camera().center;
      fakeFix(source, 1, lat: 52.5202);
      await tester.pump();
      expect(camera().center, sameCameraAs(panned));

      // The long-press is the way back: re-arms the follow and re-centers
      // on the session's fix on the spot.
      await tester.longPressAt(Offset(size.width / 2, size.height * 0.4));
      await tester.pump();
      expect(
        camera().center.latitude,
        closeTo(52.5202, 1e-6),
        reason: 'the long-press re-centered on the session fix',
      );

      // The follow is armed again: the next fix rides the camera.
      fakeFix(source, 2, lat: 52.5203);
      await pumpGlide(tester);
      expect(
        camera().center.latitude,
        greaterThan(52.5203),
        reason: 'the follow re-centered on the new fix',
      );
      expect(
        camera().center.latitude,
        lessThan(52.5203 + 1e-3),
        reason: 'the follow frames the fix (center north of it)',
      );
    },
  );

  testWidgets(
    'releasing the follow during a recording toasts the way back',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201);
      await pumpGlide(tester);

      // The session start armed the follow without a toast: the arm is
      // not something to announce.
      expect(find.byType(SnackBar), findsNothing);

      final size = tester.getSize(find.byType(FlutterMap));
      await twoFingerPan(
        tester,
        start: Offset(size.width / 2, size.height * 0.4),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Camera free — long-press the map to re-center'),
        findsOneWidget,
        reason: 'the release during a recording toasts the way back',
      );
    },
  );

  testWidgets(
    'a long-press during photo reposition does not re-center the camera',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final photoSource = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(16)));
      final model = await createModel(root, photoSource);
      model.store.importBytes(
        utf8.encode(eastwardTimedGpx('Replay walk', 4)),
      );

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      // Arm the banner mode, then start a replay with it armed: the
      // reachable combination (a session start would cancel the banner,
      // a replay start does not — the banner's taps still place the
      // pin during a replay).
      // The photo lands at the fitted track's center so its pin tap is
      // well inside the map, clear of the top chrome.
      await model.takePhoto(
        const LatLng(45.0, 9.0006),
        takenAt: DateTime.utc(2026, 11, 24),
      );
      await tester.pump();
      await _tapMapAt(tester, const LatLng(45.0, 9.0006));
      await tester.pump();
      await tester.pump();
      expect(find.byType(PhotoPreviewDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('photo-reposition')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('reposition-banner')), findsOneWidget);

      // The replay's follow-camera rides the cursor.
      model.startPlayback(model.tracks.single);
      await tester.pump(const Duration(milliseconds: 300));
      await pumpGlide(tester);

      // Release the follow with the deliberate two-finger pan (a
      // one-finger drag is a peek during a replay too), so a long-press
      // outside the banner mode would visibly re-center on the replay
      // cursor.
      final size = tester.getSize(find.byType(FlutterMap));
      await twoFingerPan(
        tester,
        start: Offset(size.width / 2, size.height * 0.4),
      );
      final panned = camera().center;

      // The long-press belongs to the banner mode: no re-arm, no
      // re-center, and the banner survives (the press never became a
      // pin-placing tap).
      await tester.longPressAt(Offset(size.width / 2, size.height * 0.4));
      await tester.pump();
      expect(
        camera().center,
        sameCameraAs(panned),
        reason: 'reposition mode swallowed the long-press',
      );
      expect(find.byKey(const ValueKey('reposition-banner')), findsOneWidget);
      expect(
        model.photos.single.lat,
        closeTo(45.0, 1e-9),
        reason: 'the long-press never placed the pin',
      );
    },
  );

  testWidgets(
    'the follow frames the fix slightly below screen center and never zooms past the floor',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      // No heading at all: the bottom-center offset still applies — with
      // the camera north-up, the center sits north of the fix, so the fix
      // renders below the vertical center.
      fakeFix(source, 0, lat: 52.5200, lon: 13.4050);
      await pumpGlide(tester);
      expect(camera().center.latitude, greaterThan(52.5200));
      expect(camera().center.longitude, closeTo(13.4050, 1e-5));
      // Zoom floor: even if the user zoomed out to 14, the follow keeps 17.
      expect(camera().zoom, greaterThanOrEqualTo(17.0));
    },
  );

  testWidgets(
    'below the speed gate the compass heading drives the rotation',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();
      final compass = StreamController<double?>();
      RecordingDashboardState.compassEvents = () => compass.stream;
      addTearDown(() {
        RecordingDashboardState.compassEvents =
            () => FlutterCompass.events!.map((e) => e.heading);
        compass.close();
      });

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      // Moving fast on an east course: camera rotates to ~-90 (east up).
      fakeFix(source, 0, heading: 90, speed: 5.0);
      for (var i = 1; i < 16; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 5.0);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 1.0));

      // Standstill with a stale GPS heading but a live compass facing
      // south: the rotation follows the compass, not the stale course.
      compass.add(180.0);
      await tester.pump();
      for (var i = 16; i < 32; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 0.2);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(180.0, 10.0));
    },
  );

  testWidgets(
    'the course/compass gate has hysteresis: no source flapping between the thresholds',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();
      final compass = StreamController<double?>();
      RecordingDashboardState.compassEvents = () => compass.stream;
      addTearDown(() {
        RecordingDashboardState.compassEvents =
            () => FlutterCompass.events!.map((e) => e.heading);
        compass.close();
      });

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      // Course mode while moving: the camera eases to -90 (east up).
      fakeFix(source, 0, heading: 90, speed: 5.0);
      for (var i = 1; i < 16; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 5.0);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 1.0));

      // The compass now faces south while the speed drops into the
      // hysteresis band (0.8 m/s: above the 0.6 enter gate, below the 1.4
      // exit gate) — still course mode, so the rotation must not swing.
      compass.add(180.0);
      await tester.pump();
      for (var i = 16; i < 24; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 0.8);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 2.0));

      // Below the enter gate: compass mode, the rotation follows the compass.
      for (var i = 24; i < 32; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 0.3);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(180.0, 10.0));

      // Rising but still inside the band (1.0 m/s): hysteresis holds the
      // compass mode.
      for (var i = 32; i < 40; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 1.0);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(180.0, 10.0));

      // Above the exit gate: back to the GPS course.
      for (var i = 40; i < 56; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 5.0);
      }
      await pumpGlide(tester);
      // The window's mean sits a couple of degrees off 90 (the alternating
      // tail), but the camera follows that smoothed mean, not the raw swing.
      expect(camera().rotation % 360, closeTo(270.0, 4.0));
    },
  );

  testWidgets(
    'noisy headings rotate the camera smoothly toward their mean',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      // A steady 90° course: the camera converges on it as before.
      fakeFix(source, 0, heading: 90, speed: 5.0);
      for (var i = 1; i < 16; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4, heading: 90, speed: 5.0);
      }
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 1.0));

      // Headings now alternate 80/100 around the course. The smoothed
      // target stays at their mean (90), so the camera must not chase the
      // raw noise: per-fix rotation steps stay far below the 10° swing
      // (the unsmoothed code would step ~4° per fix).
      var prevRotation = camera().rotation;
      for (var i = 16; i < 28; i++) {
        fakeFix(source, i, lat: 52.5201 + i * 1e-4,
            heading: i % 2 == 0 ? 80.0 : 100.0, speed: 5.0);
        // One 100 ms glide frame per fix: the camera advances only a
        // fraction of the way, so per-frame rotation steps stay far below
        // the 10° heading swing (an unsmoothed snap would step ~10°).
        await tester.pump(const Duration(milliseconds: 100));
        final r = camera().rotation;
        expect((r - prevRotation).abs(), lessThan(4.0),
            reason: 'the rotation stepped with the raw heading noise');
        prevRotation = r;
      }
      await pumpGlide(tester);
      // The window's mean sits a couple of degrees off 90 (the alternating
      // tail), but the camera follows that smoothed mean, not the raw swing.
      expect(camera().rotation % 360, closeTo(270.0, 4.0));
    },
  );

  testWidgets(
    'the chip rotation button toggles north ↔ course',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201, heading: 90, speed: 5.0);
      await tester.pump();
      await tester.pump();

      // The control pill offers the rotation-mode button; north-up default.
      final button = find.byKey(const ValueKey('rotation-mode-button'));
      expect(button, findsOneWidget);
      expect(model.mapRotation, 'north');

      await tester.tap(button);
      await tester.pump();
      expect(model.mapRotation, 'course');

      await tester.tap(button);
      await tester.pump();
      expect(model.mapRotation, 'north');
    },
  );

  testWidgets(
    'idle, the rotation button just sets north and snaps the camera',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: false,
      );
      await tester.pump();

      // A course mode persisted from an earlier session reads course...
      await model.setMapRotation('course');
      await tester.pump();
      expect(model.mapRotation, 'course');

      // ...and a manual rotate leaves the map off north.
      final controller = MapController.of(
        tester.element(find.byType(TileLayer)),
      );
      controller.rotate(90);
      await tester.pump();
      expect(controller.camera.rotation, closeTo(90.0, 1e-6));

      // One idle tap: north — and the camera actually snaps to rotation 0,
      // not a toggle that would flip the mode back to course.
      await tester.tap(find.byKey(const ValueKey('rotation-mode-button')));
      await tester.pump();
      expect(model.mapRotation, 'north');
      expect(controller.camera.rotation, closeTo(0.0, 1e-6));
    },
  );

  testWidgets(
    'by default the map stays north-up while recording; the follow still '
    'centers and the marker still points along the course',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;
      double markerAngle() {
        final m = tester
            .widget<Transform>(
              find.byKey(const ValueKey('recording-marker-rotate')),
            )
            .transform;
        return math.atan2(m.entry(1, 0), m.entry(0, 0));
      }

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, heading: 90);
      fakeFix(source, 1, lat: 52.5201, heading: 90);
      await pumpGlide(tester);

      // mapRotation defaults to north: the camera never rotates, but the
      // follow still centers on the fix (framed below screen center, so
      // north of it) and the marker still shows the course (90° east
      // against a north-up camera).
      expect(camera().rotation, closeTo(0.0, 0.1));
      expect(camera().center.latitude, greaterThan(52.5201));
      expect(markerAngle(), closeTo(math.pi / 2, 1e-6));
    },
  );

  testWidgets(
    'course-up on: the marker shows the course on screen while the camera '
    'is still easing',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;
      double markerAngle() {
        final m = tester
            .widget<Transform>(
              find.byKey(const ValueKey('recording-marker-rotate')),
            )
            .transform;
        return math.atan2(m.entry(1, 0), m.entry(0, 0));
      }

      await model.startRecording(source: source, permissionGate: false);
      // One fix on a 90° course, mid-glide after a few frames: the camera
      // has eased only partway toward -90. The marker's angle is the course
      // alone — the map's content rotation (flutter_map wraps MarkerLayer
      // children in the camera rotation) supplies the camera term on
      // screen, so adding it here would double-rotate the nose.
      fakeFix(source, 0, lat: 52.5201, heading: 90, speed: 5.0);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final rotation = camera().rotation;
      expect(rotation % 360, lessThan(350.0));
      expect(rotation % 360, greaterThan(280.0));
      expect(
        markerAngle(),
        closeTo(math.pi / 2, 0.05),
        reason: 'the marker draws the course in content space',
      );
      // Settled: the camera converges on the course and the nose nets to up.
      await pumpGlide(tester);
      expect(camera().rotation % 360, closeTo(270.0, 1.0));
      expect(markerAngle(), closeTo(math.pi / 2, 0.05));
    },
  );

  testWidgets(
    'the bearing fallback keeps the camera north-up, marker rotating',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;
      double markerAngle() {
        final m = tester
            .widget<Transform>(
              find.byKey(const ValueKey('recording-marker-rotate')),
            )
            .transform;
        return math.atan2(m.entry(1, 0), m.entry(0, 0));
      }

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      // ~7 m east of the first fix, no heading: the course is the bearing
      // the displacement bridges — but a bridged bearing is not a reported
      // heading, so it must not steer the camera.
      fakeFix(source, 1, lon: 13.4051);
      await tester.pump();
      await tester.pump();

      expect(
        camera().rotation,
        closeTo(0.0, 0.1),
        reason: 'a bearing-only stream keeps the camera north-up',
      );
      expect(
        markerAngle(),
        closeTo(math.pi / 2, 1e-6),
        reason: 'the marker still rotates along the bridged course',
      );
    },
  );

  testWidgets('while recording, locate returns the follow after a pan', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    MapCamera camera() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera;

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0);
    fakeFix(source, 1, lat: 52.5201);
    await pumpGlide(tester);

    // A deliberate two-finger pan releases the follow (one-finger drags
    // are inert while it is armed): the next fix stays where the pan put
    // it, and the toolbar keeps the Locate action to come back. (From the
    // free middle; the bottom column is occupied while recording.)
    final size = tester.getSize(find.byType(FlutterMap));
    await twoFingerPan(
      tester,
      start: Offset(size.width / 2, size.height * 0.4),
    );
    fakeFix(source, 2, lat: 52.5202);
    await pumpGlide(tester);
    final zoom = camera().zoom;
    expect(find.byTooltip('Center on current position'), findsOneWidget);

    // The tap is the way back: instant (no spinner — the session's own fix
    // needs no attempt), re-centered on the session's fix at the user's
    // zoom, and the follow re-arms — the next fix rides the camera again.
    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      camera().center.latitude,
      closeTo(52.5202, 1e-6),
      reason: 'the tap returned the camera to the session fix',
    );
    fakeFix(source, 3, lat: 52.5203);
    await pumpGlide(tester);
    // The re-armed follow frames the fix below screen center, so the
    // center sits slightly north of it.
    expect(camera().center.latitude, greaterThan(52.5203));
    expect(camera().zoom, closeTo(zoom, 1e-6));
  });

  testWidgets(
    'while recording, activating course-up re-arms a released follow',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();
      // Start from course-up so the first tap goes *to* north (the mode
      // change that must not re-arm), the second back to course.
      await model.setMapRotation('course');

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, speed: 5.0, heading: 90);
      fakeFix(source, 1, lat: 52.5201, speed: 5.0, heading: 90);
      await pumpGlide(tester);

      // A deliberate two-finger pan (one-finger drags are inert while the
      // follow is armed): the follow releases and the camera stays where
      // the hand left it; the next fix must not pull it back.
      final size = tester.getSize(find.byType(FlutterMap));
      await twoFingerPan(
        tester,
        start: Offset(size.width / 2, size.height * 0.4),
      );
      fakeFix(source, 2, lat: 52.5202, speed: 5.0, heading: 90);
      await pumpGlide(tester);
      final panned = camera().center;

      // North first: the map snaps north on the spot while the released
      // follow holds its panned center.
      await tester.tap(find.byKey(const ValueKey('rotation-mode-button')));
      await tester.pump();
      expect(model.mapRotation, 'north');
      expect(
        camera().rotation % 360,
        lessThan(1.0),
        reason: 'north snaps the map north even with the follow released',
      );
      fakeFix(source, 3, lat: 52.5203, speed: 5.0, heading: 90);
      await pumpGlide(tester);
      expect(
        (camera().center.latitude - panned.latitude).abs() < 1e-6 &&
            (camera().center.longitude - panned.longitude).abs() < 1e-6,
        isTrue,
        reason: 'north does not re-arm a released follow',
      );
      expect(
        camera().rotation % 360,
        lessThan(1.0),
        reason: 'the released follow leaves the north snap alone',
      );

      // Course: the tap re-arms the follow and re-centers on the session
      // fix, and the next fix rides the camera in course-up.
      await tester.tap(find.byKey(const ValueKey('rotation-mode-button')));
      await tester.pump();
      expect(model.mapRotation, 'course');
      expect(
        camera().center.latitude,
        closeTo(52.5203, 1e-6),
        reason: 'course activation returned the camera to the session fix',
      );
      fakeFix(source, 4, lat: 52.5204, speed: 5.0, heading: 90);
      await pumpGlide(tester);
      // The follow rides the new fix (course-up at heading 90, so the
      // framing lead is along the longitude axis, not the latitude one).
      expect(
        camera().center.latitude,
        closeTo(52.5204, 1e-3),
        reason: 'the re-armed follow rides the session fix again',
      );
      expect(
        (camera().rotation % 360 - 270.0).abs() < 2.0,
        isTrue,
        reason: 'course-up rotates the camera to the heading',
      );
      model.stopRecording();
      await tester.pump();
    },
  );

  testWidgets('while recording with no session fix, locate runs the attempt', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    MapCamera camera() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera;

    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );

    // A session started cold: nothing to shortcut on — the tap falls
    // through to the real locate attempt, whose fix arms the follow.
    await model.startRecording(source: source, permissionGate: false);
    await tester.tap(find.byTooltip('Center on current position'));
    await pumpGlide(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(camera().center.latitude, closeTo(52.5200, 1e-6));
    // The follow armed on the attempt's success: the session's fix takes
    // the camera from here (framed below screen center, so north of it).
    fakeFix(source, 0, lat: 52.5201);
    await pumpGlide(tester);
    expect(camera().center.latitude, greaterThan(52.5201));
  });

  testWidgets(
    'locate lives in the edge pill; record mirrors to the opposite edge',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      // GPS off at startup: no fix, so no Record — the pill is rotation,
      // zoom and locate only.
      mockGeolocator(tester, permission: 3, serviceEnabled: false);

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await pumpGlide(tester);

      final mapRect = tester.getRect(find.byType(FlutterMap));
      Rect rectOf(String tooltip) => tester.getRect(find.byTooltip(tooltip));

      expect(find.text('Record'), findsNothing);
      final locate = rectOf('Center on current position');
      expect(
        locate.left,
        greaterThan(mapRect.width * 0.5),
        reason: 'the pill hugs the right edge (the configured side)',
      );
      expect(
        mapRect.bottom - locate.bottom,
        greaterThan(100),
        reason: 'locate sits mid-edge, not in the bottom column',
      );
      // The top bar is untouched: Import stays up there.
      expect(tester.getRect(find.text('Import')).top, lessThan(100));

      // A fix arrives through the locate tap: the Record button appears in
      // the cluster on the opposite (left) edge, vertically centered.
      mockGeolocator(
        tester,
        permission: 3,
        position: {'lat': 52.5200, 'lon': 13.4050},
      );
      await tester.tap(find.byTooltip('Center on current position'));
      await pumpGlide(tester);
      final record = rectOf('Record');
      expect(
        record.right,
        lessThan(mapRect.width * 0.5),
        reason: 'record mirrors to the left edge, opposite the pill',
      );
      expect(record.left, closeTo(16.0, 1.0)); // 12 edge inset + 4 pill padding
      expect(
        (record.center.dy - mapRect.center.dy).abs(),
        lessThan(mapRect.height * 0.2),
        reason: 'the record cluster is vertically centered',
      );

      // While recording the slot holds Pause, still on the left edge; the
      // header keeps Tracks and Settings only.
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      await pumpGlide(tester);
      expect(find.text('Record'), findsNothing);
      expect(
        find.text('Stop'),
        findsOneWidget,
        reason: 'stop is visible the whole session, running or paused',
      );
      final pause = rectOf('Pause');
      final stop = rectOf('Stop');
      expect(
        pause.right,
        lessThan(mapRect.width * 0.5),
        reason: 'pause occupies the record slot on the left edge',
      );
      expect(
        stop.bottom,
        closeTo(pause.top, 1.0),
        reason: 'stop sits directly above pause in the cluster',
      );
      expect(stop.center.dx, closeTo(pause.center.dx, 1.0));

      // Paused: the slot reads Resume and Stop stays before it in the
      // cluster, all still on the left edge.
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      final resume = rectOf('Resume');
      final stopPaused = rectOf('Stop');
      expect(resume.right, lessThan(mapRect.width * 0.5));
      expect(
        stopPaused.bottom,
        closeTo(resume.top, 1.0),
        reason: 'stop sits before the resume button in the cluster',
      );
      expect(stopPaused.center.dx, closeTo(resume.center.dx, 1.0));
      expect(find.text('Import'), findsNothing);
      expect(tester.getRect(find.text('Tracks')).top, lessThan(100));
      // End the session without the dialog (its import never settles in
      // the fake-async zone).
      model.stopRecording();
      await tester.pump();
    },
  );

  testWidgets('dark theme darkens the tiles client-side, light leaves them', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    // Light theme: standard OSM tiles, no tile builder.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF4363D8)),
        home: MapPage(
          model: model,
          cacheDir: cache,
          versionFuture: Future.value('2026-11-12 12:00'),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder,
      isNull,
    );

    // Dark theme: tiles are inverted client-side (no new tile endpoint).
    // Several pumps: the theme switch settles a frame or two later than
    // the widget swap.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF4363D8)),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF4363D8),
          brightness: Brightness.dark,
        ),
        themeMode: ThemeMode.dark,
        home: MapPage(
          model: model,
          cacheDir: cache,
          versionFuture: Future.value('2026-11-12 12:00'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TileLayer>(find.byType(TileLayer)).tileBuilder,
      same(darkModeTileBuilder),
    );
  });

  testWidgets('unusable cache dir disables caching instead of stalling tiles', (
    tester,
  ) async {
    final root = createRoot();
    // A path whose parent chain runs through a plain file is not creatable
    // - deterministic on every filesystem, no permission tricks needed.
    final blocker = File(
      '${Directory.systemTemp.createTempSync('unvisited-blocker').path}'
      '${Platform.pathSeparator}blocker',
    )..createSync();
    addTearDown(() {
      try {
        blocker.parent.deleteSync(recursive: true);
      } on Exception {
        // Best-effort cleanup; a failure to delete temp dirs must not
        // fail the test.
      }
    });
    final model = await createModel(root);

    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          model: model,
          cacheDir: Directory('${blocker.path}${Platform.pathSeparator}cache'),
          versionFuture: Future.value('2026-11-12 12:00'),
        ),
      ),
    );
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

  testWidgets('drawer select/deselect all button toggles every track', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    // Imports go through the synchronous store path: directory scanning is
    // real async I/O, which a widget test's fake async zone never completes.
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('eiffel_ride.tcx'));
    expect(model.tracks.length, 2);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks'));
    // Fixed pumps, not pumpAndSettle: the tile-backed map keeps scheduling
    // frames, so the tree never settles inside the test environment.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.allTracksVisible, isTrue);
    // Two-phase with feedback: the tap flips the busy flag synchronously,
    // so the first frame paints the progress indicator before the rebuild
    // frame lands (one endOfFrame later).
    await tester.tap(find.byTooltip('Deselect all tracks'));
    await tester.pump();
    expect(
      find.byType(LinearProgressIndicator),
      findsOneWidget,
      reason: 'select-all shows loading feedback while rebuilding',
    );
    await tester.pump();
    await tester.pump();
    expect(model.allTracksVisible, isFalse);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byTooltip('Select all tracks'), findsOneWidget);

    await tester.tap(find.byTooltip('Select all tracks'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pump();
    await tester.pump();
    expect(model.allTracksVisible, isTrue);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a map tap selects the aggregate over it, the bar dismisses', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);

    // Tap on a real track point: tapAt refreshes the global position of
    // the tester, so convert the point through the live camera first.
    final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
    // latLngToScreenOffset is map-local; tapAt is viewport-global — the
    // map starts below the toolbar, so add its origin.
    final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
    final point = model.visibleTracks.single.points.first;
    await tester.tapAt(mapOrigin + camera.latLngToScreenOffset(point));
    // Double-tap zoom is on, so the tap detector waits out the double-tap
    // window (real time) before firing onTap.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(model.selectedAggregate, isNotNull);
    expect(model.selectedAggregate!.trackIds, [model.tracks.single.id]);
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
    // The selection actions sit in their own pill at the bottom of the
    // map, not inside the top toolbar.
    final mapRect = tester.getRect(find.byType(FlutterMap));
    final hideTop = tester.getTopLeft(
      find.byKey(const ValueKey('selection-hide')).first,
    );
    expect(hideTop.dy, greaterThan(mapRect.height * 0.5));
    // The highlight rides a second circle layer above the fog.
    expect(
      tester.widgetList<CircleLayer>(find.byType(CircleLayer)),
      hasLength(2),
    );
  });

  testWidgets('the selection bar changes the color and hides the aggregate', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
    final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
    await tester.tapAt(
      mapOrigin +
          camera.latLngToScreenOffset(model.visibleTracks.single.points.first),
    );
    // Double-tap zoom delays the tap; see the select test above.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // The color menu picks a persisted override...
    await tester.tap(find.byKey(const ValueKey('selection-color')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Blue'));
    await tester.pump();
    expect(model.store.aggregateColor(model.selectedAnchor!), 'blue');

    // ...hide deselects and hides the member tracks...
    await tester.tap(find.byKey(const ValueKey('selection-hide')));
    await tester.pump();
    expect(model.store.tracks.single.visible, isFalse);
    expect(model.selectedAggregate, isNull);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
  });

  testWidgets('hiding an aggregate fires an undo toast that restores it',
      (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
    final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
    await tester.tapAt(
      mapOrigin +
          camera.latLngToScreenOffset(model.visibleTracks.single.points.first),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(model.selectedAnchor, isNotNull);

    await tester.tap(find.byKey(const ValueKey('selection-hide')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.store.tracks.single.visible, isFalse);

    // The undo toast is showing with its action...
    expect(find.text('Area hidden'), findsOneWidget);
    expect(find.byKey(const ValueKey('undo-hide-action')), findsOneWidget);

    // ...and tapping Undo re-shows the aggregate's tracks.
    await tester.tap(find.byKey(const ValueKey('undo-hide-action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.store.tracks.single.visible, isTrue);
    expect(model.aggregates.single.trackIds, hasLength(1));
  });

  testWidgets('the undo toast fades away when left alone', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    model.selectedAnchor = model.aggregates.single.anchorId;
    model.notifyListeners();
    await tester.pump();
    await model.hideSelectedAggregate();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Area hidden'), findsOneWidget);

    // The Material default duration (4 s) plus the exit animation — and
    // the trailing pump that flushes the dismissal frame: the toast must
    // be gone, no Undo left to tap. (persist: false is what makes an
    // actioned SnackBar fade at all — Flutter 3.47 persists them by
    // default.)
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Area hidden'), findsNothing);
    expect(find.byKey(const ValueKey('undo-hide-action')), findsNothing);
  });

  testWidgets('the bar dismiss drops the selection, the tracks stay visible', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
    final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
    await tester.tapAt(
      mapOrigin +
          camera.latLngToScreenOffset(model.visibleTracks.single.points.first),
    );
    // Double-tap zoom delays the tap; see the select test above.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('selection-dismiss')));
    await tester.pump();
    expect(model.selectedAggregate, isNull);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
    expect(model.store.tracks.single.visible, isTrue);
  });

  /// Two two-point GPX tracks; distinct start times, since identical time
  /// + equal distance would trip the cross-format near-duplicate rule
  /// (±2 s AND within 10%). importBytes derives names from the bytes, so
  /// tests identify tracks by import order.
  String twoPointGpx(double lon, String time) =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<gpx version="1.1" creator="test"><trk><trkseg>'
      '<trkpt lat="45.0" lon="$lon"><time>$time</time></trkpt>'
      '<trkpt lat="45.0" lon="${lon + 0.0001}">'
      '<time>$time</time></trkpt>'
      '</trkseg></trk></gpx>\n';

  Future<void> tapAtMapPoint(WidgetTester tester, AppModel model, LatLng p) async {
    final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
    final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
    await tester.tapAt(mapOrigin + camera.latLngToScreenOffset(p));
    // Double-tap zoom delays the tap; see the select tests above.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  LatLng firstPointOf(AppModel model, String id) =>
      model.pointsOf(model.store.tracks.singleWhere((t) => t.id == id)).first;

  testWidgets(
    'member-picking: lanes on the map, tap picks one into a bubble, hide / '
    'show / hide-others, tap-away exits',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = AppModel(TrackStore(root));
      model.store.importBytes(
          utf8.encode(twoPointGpx(9.0, '2026-06-01T08:00:00Z')));
      model.store.importBytes(
          utf8.encode(twoPointGpx(9.0002, '2026-06-02T08:00:00Z')));
      final aId = model.store.tracks.first.id;
      final bId = model.store.tracks.last.id;
      expect(model.aggregates.single.trackIds, hasLength(2));

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: false,
      );
      await tester.pump();

      // Select the aggregate via a map tap, like a user would.
      await tapAtMapPoint(tester, model, firstPointOf(model, aId));
      expect(model.selectedAnchor, isNotNull);
      expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
      expect(model.memberPicking, isFalse);

      // The tracks button enters picking mode: member lanes are drawn (the
      // fog is circles by default, so a PolylineLayer is the member layer)
      // with distinct colors for the two near tracks, and the toast says
      // what the mode is.
      await tester.tap(find.byKey(const ValueKey('selection-tracks')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.memberPicking, isTrue);
      expect(find.byType(PolylineLayer), findsWidgets);
      expect(find.text('Tap a track to pick it'), findsOneWidget);
      final lanes = model.memberAssignments;
      expect(lanes[aId]!.tintKey == lanes[bId]!.tintKey, isFalse);
      expect(lanes[aId]!.lane == lanes[bId]!.lane, isFalse);

      // A map tap on Beta's lane picks Beta: the bubble floats on the map
      // with its actions.
      await tapAtMapPoint(tester, model, firstPointOf(model, bId));
      expect(model.pickedMemberId, bId);
      expect(model.selectedAnchor, isNotNull);
      expect(find.byKey(const ValueKey('member-bubble')), findsOneWidget);
      expect(find.byKey(const ValueKey('member-bubble-hide')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('member-bubble-hide-others')), findsOneWidget);

      // Hide this track: Beta becomes a ghost lane (still drawn, dashed),
      // the bubble closes, the selection survives (the anchor is Alpha).
      await tester.tap(find.byKey(const ValueKey('member-bubble-hide')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.store.tracks.singleWhere((t) => t.id == bId).visible,
          isFalse);
      expect(model.pickedMemberId, isNull);
      expect(find.byKey(const ValueKey('member-bubble')), findsNothing);
      expect(model.selectedAnchor, aId);
      expect(model.selectedAggregate?.trackIds, [aId]);
      expect(find.byType(PolylineLayer), findsWidgets,
          reason: 'the ghost lane is still drawn');

      // Tapping the ghost lane opens the bubble with the show action;
      // showing restores the track and the two-track aggregate.
      await tapAtMapPoint(tester, model, firstPointOf(model, bId));
      expect(model.pickedMemberId, bId);
      expect(find.byKey(const ValueKey('member-bubble-show')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('member-bubble-show')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.store.tracks.singleWhere((t) => t.id == bId).visible,
          isTrue);
      expect(model.selectedAggregate?.trackIds, hasLength(2));

      // Hide the others: Alpha leaves, Beta stays, the selection
      // re-anchors to Beta (the anchor Alpha was hidden).
      await tapAtMapPoint(tester, model, firstPointOf(model, bId));
      expect(model.pickedMemberId, bId);
      await tester.tap(
          find.byKey(const ValueKey('member-bubble-hide-others')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(model.store.tracks.singleWhere((t) => t.id == aId).visible,
          isFalse);
      expect(model.store.tracks.singleWhere((t) => t.id == bId).visible,
          isTrue);
      expect(model.selectedAnchor, bId);
      expect(model.selectedAggregate?.trackIds, [bId]);

      // A tap away from every lane exits picking mode.
      final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
      await tester.tapAt(mapOrigin + const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(model.memberPicking, isFalse);
      expect(model.pickedMemberId, isNull);
    },
  );

  testWidgets(
    'a repeated tap where two coincident lanes converge cycles the pick',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = AppModel(TrackStore(root));
      // Alpha and Gamma share the exact geometry (different start times,
      // so the near-duplicate rule does not fire): their lanes sit 3 px
      // apart, a tie at a crossing.
      model.store.importBytes(
          utf8.encode(twoPointGpx(9.0, '2026-06-01T08:00:00Z')));
      model.store.importBytes(
          utf8.encode(twoPointGpx(9.0, '2026-06-03T08:00:00Z')));
      final ids = model.store.tracks.map((t) => t.id).toList();
      expect(model.aggregates.single.trackIds, hasLength(2));

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: false,
      );
      await tester.pump();

      await tapAtMapPoint(tester, model, firstPointOf(model, ids.first));
      expect(model.selectedAnchor, isNotNull);
      await tester.tap(find.byKey(const ValueKey('selection-tracks')));
      await tester.pump();
      expect(model.memberPicking, isTrue);

      final point = firstPointOf(model, ids.first);
      await tapAtMapPoint(tester, model, point);
      final firstPick = model.pickedMemberId;
      expect(firstPick, isNotNull);
      // Let the double-tap window expire so the next tap is a tap, not a
      // (clamped, invisible at max zoom) double-tap zoom.
      await tester.pump(const Duration(seconds: 1));
      // Again at (almost) the same spot — 40 px over, inside the 48 px
      // same-spot window but past the double-tap slop (36 px), so the
      // gesture is a tap, not a zoom: the tie promotes the other lane.
      final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
      final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
      await tester.tapAt(
          mapOrigin + camera.latLngToScreenOffset(point) + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(model.pickedMemberId, isNotNull);
      expect(model.pickedMemberId, isNot(firstPick),
          reason: 'the tie promotes the other coincident lane');
      expect(model.pickedMemberId, ids.firstWhere((id) => id != firstPick));
    },
  );

  testWidgets(
    'selection bar and recording chip stack in the bottom column, below the actions',
    (tester) async {
      // Narrow phone surface: the bars must not overlap each other, the
      // action stack, or the top toolbar.
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = createRoot();
      final cache = createCache();
      final model = AppModel(TrackStore(root));
      model.store.importBytes(fixture('morning_walk.gpx'));
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      // Idle: neither bar; the toolbar is the only thing at the top.
      expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
      expect(find.byKey(const ValueKey('recording-chip')), findsNothing);
      final mapRect = tester.getRect(find.byType(FlutterMap));
      final toolbar = tester.getRect(
        find.widgetWithText(FloatingToolbar, 'Tracks'),
      );
      expect(toolbar.top, lessThan(mapRect.height * 0.5));

      // Select the aggregate (a map tap is owned by the recording UI once
      // a session runs, so set the selection directly), then start a
      // session: both bars must show in the bottom half, stacked in the
      // column without overlap, below the action stack at the bottom edge.
      model.selectedAnchor = model.aggregates.single.anchorId;
      model.notifyListeners();
      await tester.pump();
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-chip')), findsOneWidget);
      final selection = tester.getRect(
        find.byKey(const ValueKey('selection-bar')),
      );
      final chip = tester.getRect(
        find.byKey(const ValueKey('recording-chip')),
      );
      final speed = tester.getRect(find.byKey(const ValueKey('recording-speed')));
      // The pill's locate slot is retired while the session's follow is
      // armed; the pill body itself (rotation + zoom steps) remains and
      // must still not be overlapped.
      expect(
        find.byTooltip('Center on current position'),
        findsNothing,
        reason: 'the armed follow retires the locate slot',
      );
      final pill = tester.getRect(find.byKey(const ValueKey('control-pill')));
      // All bars sit below the toolbar (at the bottom of the map), stacked
      // in the column without overlap, with the bars ending at the bottom
      // edge below the action stack.
      for (final r in [selection, chip]) {
        expect(r.top, greaterThan(toolbar.bottom));
      }
      expect(selection.top, greaterThanOrEqualTo(pill.bottom));
      expect(chip.top, greaterThanOrEqualTo(selection.bottom));
      // The headline speed lives in the top bar's center while recording
      // (out of the bottom column), riding inside the pill — which just
      // widened by the segment, so re-measure it.
      final toolbarNow = tester.getRect(
        find.widgetWithText(FloatingToolbar, 'Tracks'),
      );
      expect(toolbarNow.contains(speed.topLeft), isTrue);
      expect(toolbarNow.contains(speed.bottomRight), isTrue);
      expect(
        mapRect.bottom - chip.bottom,
        closeTo(20.0, 1.0),
        reason: 'the chip clears the bottom safe-area inset',
      );

      // End the session without the dialog (its import never settles in
      // the fake-async zone).
      model.stopRecording();
      await tester.pump();
    },
  );

  testWidgets('the empty-state hint hides when tracks exist, selected or not', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
    await tester.pump();

    // Empty catalog, idle: the hint is the map's whole message.
    expect(find.text('No tracks yet'), findsOneWidget);

    // Tracks imported but all deselected: no hint — it would lie about
    // the catalog.
    model.store.importBytes(fixture('morning_walk.gpx'));
    await model.setAllVisible(false);
    await tester.pump();
    expect(find.text('No tracks yet'), findsNothing);
    await model.setAllVisible(true);
    await tester.pump();
    expect(
      find.text('No tracks yet'),
      findsNothing,
      reason: 'a plotted track replaces the hint',
    );
  });

  testWidgets('the empty-state hint hides while a session records', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.text('No tracks yet'),
      findsOneWidget,
      reason: 'a genuinely empty map keeps the hint',
    );

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0);
    await tester.pump();
    await tester.pump();
    expect(
      find.text('No tracks yet'),
      findsNothing,
      reason: 'recording must not have the hint on top of the dashboard',
    );
    expect(find.byKey(const ValueKey('recording-chip')), findsOneWidget);
  });

  testWidgets('track tile menu delete entry removes the track', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    expect(model.tracks.length, 1);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final tracksDir = Directory('${root.path}${Platform.pathSeparator}tracks');
    expect(tracksDir.listSync().length, 1);

    Future<void> openMenu() async {
      await tester.tap(find.byTooltip('Track actions'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    // The menu's delete entry asks first: declining keeps track and file.
    await openMenu();
    await tester.tap(find.text('Delete track'));
    await tester.pump();
    expect(find.text('Delete "Morning walk"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.tracks, isNotEmpty);
    expect(tracksDir.listSync(), isNotEmpty);

    // Confirming removes the track and its file.
    await openMenu();
    await tester.tap(find.text('Delete track'));
    await tester.pump();
    await tester.tap(find.text('Delete'));
    await tester.pump();

    expect(model.tracks, isEmpty);
    expect(tracksDir.listSync(), isEmpty);
  });

  testWidgets('the track menu carries Info, Delete and Export', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Track actions'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Delete track'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
  });

  testWidgets('track info dialog shows the catalog metadata', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Track actions'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Info'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The dialog title is the track name; every metadata row renders.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Morning walk'), findsAtLeastNWidgets(1));
    expect(find.text('Started'), findsOneWidget);
    expect(find.text('Format'), findsOneWidget);
    expect(find.text('Points'), findsOneWidget);
    expect(find.text('Distance'), findsOneWidget);
    expect(find.text('Duration'), findsOneWidget);
    expect(find.text('Average speed'), findsOneWidget);
    // The fixture carries a start time and duration, so no '—' anywhere.
    expect(find.text('—'), findsNothing);

    // Closing brings the drawer back unchanged (the dialog's exit
    // animation takes the usual 300 ms out of the sheet too).
    await tester.tap(find.byType(TextButton));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    expect(model.tracks, isNotEmpty);
  });

  testWidgets('the menu Export writes the stored bytes and toasts', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    final stored = model.store.trackFileFor(model.tracks.single);
    final target = File('${root.path}${Platform.pathSeparator}export.gpx');
    FilePickerPlatform.instance = FakeSavePicker(target.path);
    addTearDown(() {
      FilePickerPlatform.instance = MethodChannelFilePicker();
    });

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Track actions'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Export'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // The bytes went through unchanged and the toast says so.
    expect(target.existsSync(), isTrue);
    expect(target.readAsBytesSync(), stored.readAsBytesSync());
    expect(find.text('Track exported'), findsOneWidget);
  });

  testWidgets('track tiles carry their aggregate color', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    // Two co-located tracks (one aggregate) and a distant third.
    String gpx(double lat, double lon, DateTime start) =>
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="test"><trk><name>x</name><trkseg>'
        '<trkpt lat="$lat" lon="$lon"><time>${start.toIso8601String()}</time></trkpt>'
        '</trkseg></trk></gpx>\n';
    final t0 = DateTime.utc(2026, 6, 1, 8);
    model.store.importBytes(utf8.encode(gpx(45.0, 9.0, t0)));
    model.store.importBytes(
      utf8.encode(gpx(45.0, 9.0002, t0.add(const Duration(days: 3)))),
    );
    model.store.importBytes(
      utf8.encode(gpx(48.85, 2.35, t0.add(const Duration(days: 6)))),
    );
    expect(model.tracks.length, 3);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    Color dotColor(String trackId) {
      final container = tester.widget<Container>(
        find.byKey(ValueKey('track-dot-$trackId')),
      );
      return (container.decoration as BoxDecoration).color!;
    }

    final ids = model.tracks.map((t) => t.id).toList();
    // Oldest aggregate: green (the fixed default). The Paris aggregate:
    // the next palette color. The two clustered tiles share a color.
    // (The dot draws solid — withValues(alpha: 1) — so compare the opaque
    // counterparts.)
    expect(dotColor(ids[0]), exploredAreaColor('green').withValues(alpha: 1));
    expect(dotColor(ids[1]), exploredAreaColor('green').withValues(alpha: 1));
    expect(dotColor(ids[2]), exploredAreaColor('blue').withValues(alpha: 1));
  });

  testWidgets('tapping a track tile fits the track and nothing else', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('eiffel_ride.tcx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
    expect(model.selectedAnchor, isNull);

    double zoom() => MapCamera.of(tester.element(find.byType(TileLayer))).zoom;

    // The startup camera fits both distant aggregates; tapping a tile —
    // the name or the row below it — jumps the camera to that track's
    // own points. Nothing else: no aggregate selection (the selection
    // bar stays hidden), no visibility change — the checkbox is the
    // tile's only toggling element.
    final before = zoom();
    await tester.tap(find.text('Morning walk'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.selectedAnchor, isNull);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
    expect(
      zoom(),
      greaterThan(before),
      reason: 'fitting one track zooms in over the Europe-wide fit',
    );
    expect(
      model.tracks
          .firstWhere((t) => t.name == 'Morning walk')
          .visible,
      isTrue,
    );

    // The row below (the subtitle line) taps the same way.
    final afterName = zoom();
    await tester.tap(find.textContaining('GPX'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(zoom(), closeTo(afterName, 0.01));
    expect(model.selectedAnchor, isNull);
  });

  testWidgets('a drawer swipe deletes only after confirmation', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final tracksDir = Directory('${root.path}${Platform.pathSeparator}tracks');
    expect(tracksDir.listSync().length, 1);

    // A swipe pops the dialog first; cancelling keeps everything.
    await tester.drag(find.byType(Dismissible), const Offset(-600, 0));
    await tester.pump();
    expect(find.text('Delete "Morning walk"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    // Let the dialog's exit animation finish before touching the tile
    // again: a drag during it would land on the scrim, not the tile.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.tracks, isNotEmpty);
    expect(find.byType(Dismissible), findsOneWidget);

    // Swipe again, confirm: the track and its file are gone.
    await tester.drag(find.byType(Dismissible), const Offset(-600, 0));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Delete "Morning walk"?'),
      findsOneWidget,
      reason: 'the second swipe must reopen the dialog',
    );
    await tester.tap(find.text('Delete'));
    await tester.pump();
    // The confirmed dismissal still walks its slide-out animation; given
    // generous fake-async time it completes and fires onDismissed.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byType(Dismissible),
      findsNothing,
      reason: 'confirmed dismissal removes the tile',
    );
    expect(model.tracks, isEmpty);
    expect(tracksDir.listSync(), isEmpty);
  });

  testWidgets('the track tile shows the point-timestamp duration', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    // A track without timestamps shows a dash where a duration would be.
    const timeless =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="unvisited" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n'
        '<trk><name>No time</name>\n<trkseg>\n'
        '<trkpt lat="52.5200" lon="13.4050"><ele>38.5</ele></trkpt>\n'
        '<trkpt lat="52.5210" lon="13.4060"><ele>39.0</ele></trkpt>\n'
        '</trkseg></trk></gpx>\n';
    model.store.importBytes(timeless.codeUnits, filename: 'no-time.gpx');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 07:05:00 → 07:09:00, formatted by the one zero-padded duration.
    expect(find.textContaining('· 04:00'), findsOneWidget);
    expect(
      find.textContaining('· —'),
      findsOneWidget,
      reason: 'the timestamp-less track reads a dash for duration',
    );
    // The filename usually carries the date; the tile does not repeat it.
    expect(find.textContaining('2024-05-01'), findsNothing);
  });

  testWidgets('the track list is ordered most-recent-first, timeless last', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    // Imports in deliberately mixed chronological order: 07:05, 18:00,
    // 08:00, then a timestamp-less track.
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('recorded_ride.gpx'));
    model.store.importBytes(fixture('activity_ride.gpx'));
    const timeless =
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="unvisited" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n'
        '<trk><name>No time</name>\n<trkseg>\n'
        '<trkpt lat="52.5200" lon="13.4050"><ele>38.5</ele></trkpt>\n'
        '<trkpt lat="52.5210" lon="13.4060"><ele>39.0</ele></trkpt>\n'
        '</trkseg></trk></gpx>\n';
    model.store.importBytes(timeless.codeUnits, filename: 'no-time.gpx');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.tap(find.byTooltip('Tracks')); // open the drawer
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // The tiles' callbacks expose their tracks; read them in the order
    // they are displayed.
    final displayed = tester
        .widgetList<Dismissible>(find.byType(Dismissible))
        .map((d) => (d.key as ValueKey).value as String)
        .map(
          (key) =>
              model.store.tracks.firstWhere((t) => key == 'track-${t.id}').name,
        )
        .toList();
    expect(displayed, [
      'Evening walk', // 18:00 — the recorded ride
      'Morning ride', // 08:00
      'Morning walk', // 07:05
      'No time', // no timestamps at all: last regardless of import order
    ]);
  });

  testWidgets('header actions carry labels naming what they do', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );

    for (final label in const ['Import', 'Locate', 'Tracks', 'Settings']) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'the $label action must be captioned',
      );
    }
    // The global Fit button is gone; fitting is per aggregate via
    // selection.
    expect(find.text('Fit'), findsNothing);
  });

  testWidgets('the UI renders in Italian when the locale is Italian', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Toolbar captions.
    for (final label in const [
      'Importa',
      'Posizione',
      'Tracce',
      'Impostazioni',
    ]) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'the $label action must be captioned',
      );
    }
    expect(find.text('Import'), findsNothing);
    // Empty-map hint.
    expect(find.text('Ancora nessuna traccia'), findsOneWidget);

    // Settings sheet.
    await tester.tap(find.text('Impostazioni'));
    await tester.pumpAndSettle();
    expect(find.text('Colore della traccia'), findsOneWidget);
    expect(find.text('Lato dei controlli'), findsOneWidget);
    expect(find.text('Sinistra'), findsOneWidget);
    expect(find.text('Elimina tutte le tracce'), findsOneWidget);
    expect(find.text('Nessuna traccia archiviata'), findsOneWidget);
    expect(find.textContaining('Data di build:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visited tracks plot as fog-of-war unlock circles', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('eiffel_ride.tcx'));
    expect(model.tracks.length, 2);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    // The polylines are gone by design: the fog-of-war overlay replaces
    // them — one translucent circle per unlocked grid cell.
    expect(find.byType(PolylineLayer), findsNothing);
    final circles = tester
        .widget<CircleLayer>(find.byType(CircleLayer))
        .circles;
    expect(circles, isNotEmpty);
    expect(
      circles.every((c) => c.useRadiusInMeter),
      isTrue,
      reason: 'unlock circles are sized as real ground areas',
    );
    expect(
      circles.every((c) => explorationTints.values.contains(c.color)),
      isTrue,
      reason: 'circles draw in palette colors (per aggregate)',
    );
    // Two distant tracks: two aggregates — the oldest stays on the default
    // tint, the other takes the next palette color.
    final colors = circles.map((c) => c.color).toSet();
    expect(colors, contains(exploredAreaColor('green')));
    expect(colors, contains(exploredAreaColor('blue')));
    expect(
      circles.every((c) => c.radius >= unlockRadiusMeters - 1e-9),
      isTrue,
      reason: 'never smaller than the base unlock radius',
    );
  });

  // A 150-point northward corridor (~330 m — longer than the 100 m
  // segment gap, so two members always split into their own segments).
  // The same geometry twice, with different names and start times, is
  // two catalog tracks in one aggregate riding identical ground.
  String corridorGpx(String name, DateTime start) {
    final sink = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>\n')
      ..write(
        '<gpx version="1.1" creator="unvisited" '
        'xmlns="http://www.topografix.com/GPX/1/1">\n',
      )
      ..write('<trk><name>$name</name>\n<trkseg>\n');
    for (var i = 0; i < 150; i++) {
      final t = start.add(Duration(seconds: 2 * i));
      sink.write(
        '<trkpt lat="${(52.52 + i * 0.00002).toStringAsFixed(6)}" '
        'lon="13.405000">\n'
        '<ele>42.00</ele>\n<time>${t.toIso8601String()}</time>\n</trkpt>\n',
      );
    }
    sink.write('</trkseg>\n</trk>\n</gpx>\n');
    return sink.toString();
  }

  testWidgets('overlapping member tracks draw the union once, not twice', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(
      corridorGpx('Ride A', DateTime.utc(2024, 5, 1, 7)).codeUnits,
    );
    model.store.importBytes(
      corridorGpx('Ride B', DateTime.utc(2024, 5, 1, 9)).codeUnits,
    );
    expect(model.tracks.length, 2);
    await model.setFogStyle('polyline');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    // One aggregate, two members riding the same corridor.
    expect(model.aggregates, hasLength(1));
    expect(model.aggregates.single.members, hasLength(2));
    expect(find.byType(PolylineLayer), findsOneWidget);
    final doubled = tester
        .widget<PolylineLayer>(find.byType(PolylineLayer))
        .polylines;

    // The same catalog with a single member: identical fog lines — the
    // second member's ground was already claimed, so it added nothing.
    final single = await () async {
      final model2 = AppModel(TrackStore(createRoot()));
      model2.store.importBytes(
        corridorGpx('Ride A', DateTime.utc(2024, 5, 1, 7)).codeUnits,
      );
      await model2.setFogStyle('polyline');
      await pumpMapPage(
        tester,
        model: model2,
        cache: createCache(),
        locationSupported: false,
      );
      await tester.pump();
      return tester
          .widget<PolylineLayer>(find.byType(PolylineLayer))
          .polylines;
    }();
    expect(doubled, hasLength(single.length));
    expect(
      [for (final p in doubled) ...p.points],
      [for (final p in single) ...p.points],
      reason: 'the union is drawn once — not once per member',
    );
  });

  testWidgets('overlapping member tracks unlock each cell exactly once', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(
      corridorGpx('Ride A', DateTime.utc(2024, 5, 1, 7)).codeUnits,
    );
    model.store.importBytes(
      corridorGpx('Ride B', DateTime.utc(2024, 5, 1, 9)).codeUnits,
    );
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();
    final doubled = tester.widget<CircleLayer>(find.byType(CircleLayer)).circles;

    final model2 = AppModel(TrackStore(createRoot()));
    model2.store.importBytes(
      corridorGpx('Ride A', DateTime.utc(2024, 5, 1, 7)).codeUnits,
    );
    await pumpMapPage(
      tester,
      model: model2,
      cache: createCache(),
      locationSupported: false,
    );
    await tester.pump();
    final single =
        tester.widget<CircleLayer>(find.byType(CircleLayer)).circles;

    expect(doubled.length, single.length,
        reason: 'a cell already unlocked is not unlocked again');
  });

  testWidgets('the selection highlight dedups its own overlapping members', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(
      corridorGpx('Ride A', DateTime.utc(2024, 5, 1, 7)).codeUnits,
    );
    model.store.importBytes(
      corridorGpx('Ride B', DateTime.utc(2024, 5, 1, 9)).codeUnits,
    );
    await model.setFogStyle('polyline');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    // Tap a corridor point to select the aggregate.
    final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
    final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
    final point = model.visibleTracks.first.points.first;
    await tester.tapAt(mapOrigin + camera.latLngToScreenOffset(point));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(model.selectedAggregate, isNotNull);

    // The highlight layer (stroke 4.5) draws the union once — both
    // members, 150 shared points, not 300.
    final highlight = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .where((p) => p.strokeWidth == 4.5)
        .toList();
    expect(highlight, isNotEmpty);
    expect(
      [for (final p in highlight) ...p.points],
      hasLength(150),
      reason: 'member overlap inside the selection is not overdrawn',
    );
  });

  testWidgets('the fog style setting swaps circles for lines on the map', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    expect(model.tracks.length, 1);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    // Default: fog circles, no polylines.
    expect(find.byType(CircleLayer), findsOneWidget);
    expect(find.byType(PolylineLayer), findsNothing);

    // Open Settings and pick the line style.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Pencil'));
    await tester.pump();
    await tester.tap(find.text('Pencil'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.fogStyle, 'polyline');

    // The sheet is still up; close it and the map repaints with lines.
    Navigator.of(tester.element(find.text('Trace style'))).pop();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircleLayer), findsNothing);
    final lines = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .toList();
    expect(lines, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ink mode draws meter-sized strokes; selection follows style', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    await model.setFogStyle('ink');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    expect(find.byType(CircleLayer), findsNothing);
    final layers = tester.widgetList<PolylineLayer>(find.byType(PolylineLayer));
    final inkPolylines = layers.expand((l) => l.polylines).toList();
    expect(inkPolylines, isNotEmpty);
    // The core pass is sized in ground meters: the thinnest stroke is the
    // 10 m base times the core pass factor, flagged meter-sized so
    // flutter_map converts it to pixels at paint time (no per-zoom rebuild).
    final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
    final coreWidth = inkWidthMeters * 0.7;
    expect(
      inkPolylines.map((p) => p.strokeWidth).reduce((a, b) => a < b ? a : b),
      coreWidth,
    );
    expect(inkPolylines.every((p) => p.useStrokeWidthInMeter), isTrue);
    // Layered passes, not one flat stroke.
    expect(inkPolylines.map((p) => p.strokeWidth).toSet().length, greaterThan(1));

    // Selecting the track in ink mode highlights with ink strokes (no
    // circle highlight layer appears).
    final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
    final point = model.visibleTracks.single.points.first;
    await tester.tapAt(mapOrigin + camera.latLngToScreenOffset(point));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(model.selectedAggregate, isNotNull);
    expect(find.byType(CircleLayer), findsNothing);

    // The ink colour follows the aggregate's tint: the multitrack colour
    // override repaints the strokes with the derived ink colour.
    Color fogColor() => tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .first
        .color;
    final before = fogColor();
    expect(before, inkColorFor('green').withValues(alpha: 0.25));
    await model.setAggregateColor('orange');
    await tester.pump();
    expect(fogColor(), isNot(before));
    expect(fogColor(), inkColorFor('orange').withValues(alpha: 0.25));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings sheet shows the About card and delete-all entry', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    expect(model.tracks.length, 1);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
      buildTime: '2026-11-12 17:41',
    );

    await tester.tap(find.byTooltip('Settings'));
    // Fixed pumps, not pumpAndSettle: the tile-backed map never settles.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Two 'Settings' texts: the header caption behind the modal sheet
    // and the sheet's own header.
    expect(find.text('Settings'), findsNWidgets(2));
    expect(
      find.text('Unvisited'),
      findsOneWidget, // About card
      reason: 'the app-bar title is gone; only the About card names it',
    );
    expect(find.text('Build date: 2026-11-12 17:41'), findsOneWidget);
    expect(find.text('GitHub repository'), findsOneWidget);
    expect(find.text('Delete all tracks'), findsOneWidget);
    expect(find.text('1 stored'), findsOneWidget);
  });

  testWidgets('settings delete-all removes files only after confirmation', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('eiffel_ride.tcx'));
    final tracksDir = Directory('${root.path}${Platform.pathSeparator}tracks');
    expect(tracksDir.listSync().length, 2);

    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          model: model,
          cacheDir: cache,
          versionFuture: Future.value('2026-11-12 12:00'),
        ),
      ),
    );

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

  testWidgets('one Import button offers files and folder import', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          model: model,
          cacheDir: cache,
          versionFuture: Future.value('2026-11-12 12:00'),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Import tracks'));
    // Fixed pumps, not pumpAndSettle: the tile-backed map never settles.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Track files'), findsOneWidget);
    expect(find.text('A folder'), findsOneWidget);
  });

  testWidgets(
    'map starts at the last saved position when there are no tracks',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = AppModel(TrackStore(root));
      await model.store.savePosition(-33.8688, 151.2093);
      await model.load();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: false,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final center = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .options
          .initialCenter;
      expect(center.latitude, closeTo(-33.8688, 1e-9));
      expect(center.longitude, closeTo(151.2093, 1e-9));
    },
  );

  /// Pumps a MapPage wide enough that every header action is tappable.
  Future<AppModel> pumpMap(
    WidgetTester tester, {
    bool locationSupported = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          model: model,
          cacheDir: cache,
          versionFuture: Future.value('2026-11-12 12:00'),
          locationSupported: locationSupported,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return model;
  }

  testWidgets('a tasteful soft notification ask fires once at the Record tap', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    // GPS working (the slice 6 gate) and the host refusing the
    // notification ask: recording's FGS proceeds mute, per the confirmed
    // default, and the tap's flow must carry on undisturbed.
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );
    final hostCalls = <String>[];
    const host = MethodChannel('unvisited/host');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(host, (
      call,
    ) async {
      hostCalls.add(call.method);
      return call.method == 'requestPostNotifications' ? false : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        host,
        null,
      ),
    );

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Record'));
    // The ask fires without blocking the flow: denied, the session still
    // starts (mute FGS — the confirmed default), the chip shows it.
    await tester.pump();
    await tester.pump();
    expect(hostCalls.where((m) => m == 'requestPostNotifications').length, 1);
    expect(find.byKey(const ValueKey('recording-chip')), findsOneWidget);

    // Stop (unawaited: only the synchronous clear matters here), then a
    // second tap must not nag again.
    model.stopRecording();
    await tester.pump();
    await tester.tap(find.byTooltip('Record'));
    await tester.pump();
    await tester.pump();
    expect(hostCalls.where((m) => m == 'requestPostNotifications').length, 1);
  });

  testWidgets('the live recording trace plots while a session runs', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    // Idle: no live trace layer beyond the (empty) corridors layer.
    int tracePolylines() => tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .where((p) => p.color.r == recordingTraceColor('red').r)
        .length;
    expect(tracePolylines(), 0);

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0);
    // 22.2 m from fix(0): past the thinning threshold, so the live trace
    // (staged points only) carries both.
    fakeFix(source, 1, prevLat: 52.5200, lat: 52.5202);
    await tester.pump();
    await tester.pump();

    // While recording, one recording-red polyline carries the two staged
    // fixes — distinct from the catalog tint. The fake fixes carry an old
    // timestamp, so the age fade has dimmed it below the full trace alpha.
    expect(tracePolylines(), 1);
    final trace = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .singleWhere((p) => p.color.r == recordingTraceColor('red').r);
    expect(trace.points.length, 2);
    expect(trace.color.a, lessThan(recordingTraceColor('red').a));

    // After stop the live trace is gone (the finalized track joins the
    // catalog instead — that import's real IO never settles in the
    // fake-async zone, so only the trace's disappearance is asserted).
    model.stopRecording();
    await tester.pump();
    expect(tracePolylines(), 0);
  });

  testWidgets('locate is not offered where the platform has no location '
      'plugin', (tester) async {
    // Desktop Linux: geolocator has no implementation, so the action could
    // only ever fail.
    await pumpMap(tester, locationSupported: false);

    expect(find.text('Locate'), findsNothing);
    expect(find.byTooltip('Center on current position'), findsNothing);
    expect(
      find.text('Record'),
      findsNothing,
      reason: 'no location support means no fix can ever arrive',
    );
    // The rest of the toolbar is untouched.
    expect(find.text('Import'), findsOneWidget);
  });

  testWidgets('no fix yet means no Record button; a later fix reveals it', (
    tester,
  ) async {
    // GPS off at startup: the one-shot poll fails, the button must be
    // hidden — dead, never tappable — and stay hidden until a fix
    // actually arrives through the retry loop.
    mockGeolocator(tester, permission: 3, serviceEnabled: false);
    await pumpMap(tester);
    expect(find.text('Record'), findsNothing);

    // GPS comes on and delivers a fix: the next silent retry (30 s)
    // picks it up and the button appears with no restart.
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('a fix at startup shows the Record button immediately', (
    tester,
  ) async {
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );
    await pumpMap(tester);
    // The startup silent poll's fix already opened the gate: no wait for
    // the retry loop.
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('a stale cached fix does not reveal the Record button', (
    tester,
  ) async {
    // The fused provider's cache artifact: a position with an old
    // timestamp is not a current fix, so the silent poll must not open
    // the Record gate — and neither must the 30 s retry while it stays
    // stale.
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
      staleFix: true,
    );
    await pumpMap(tester);
    expect(find.text('Record'), findsNothing);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(find.text('Record'), findsNothing);
    expect(find.byIcon(Icons.location_on), findsNothing);
  });

  testWidgets(
    'a stale fix from the Locate button fails honestly and keeps Record hidden',
    (tester) async {
      mockGeolocator(tester, permission: 1); // denied at startup
      await pumpMap(tester);
      expect(find.text('Record'), findsNothing);

      mockGeolocator(
        tester,
        permission: 3,
        position: {'lat': 48.8584, 'lon': 2.2945},
        staleFix: true,
      );
      await tester.tap(find.byTooltip('Center on current position'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Location unavailable'), findsOneWidget);
      expect(find.text('Record'), findsNothing);
      expect(find.byIcon(Icons.location_on), findsNothing);
    },
  );

  testWidgets('a successful locate opens the Record button without waiting', (
    tester,
  ) async {
    // No fix at startup; the user asks the Locate button, which prompts.
    mockGeolocator(tester, permission: 1); // denied: silently not asked yet
    await pumpMap(tester);
    expect(find.text('Record'), findsNothing);

    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 48.8584, 'lon': 2.2945},
    );
    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('Record'),
      findsOneWidget,
      reason: 'a real fix landed, via Locate rather than the retry',
    );
  });

  testWidgets('locate centers on the fix and zooms in', (tester) async {
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 48.8584, 'lon': 2.2945},
    );
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

  testWidgets('a successful locate shows the position marker', (tester) async {
    // Mock only after the startup pump: the silent startup fix would
    // otherwise already place the marker before the button is tapped.
    await pumpMap(tester);
    expect(find.byType(MarkerLayer), findsNothing);

    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 48.8584, 'lon': 2.2945},
    );
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

  testWidgets('panning away from the fix drops the position marker', (
    tester,
  ) async {
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 48.8584, 'lon': 2.2945},
    );
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

  testWidgets('locate shows a spinner while the fix is in flight', (
    tester,
  ) async {
    mockGeolocator(
      tester,
      permission: 3,
      fixDelay: const Duration(seconds: 2),
      position: {'lat': 48.8584, 'lon': 2.2945},
    );
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

    expect(
      find.textContaining('Location permission is blocked'),
      findsOneWidget,
    );
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

  testWidgets('the edge pill steps the camera zoom with the +/− buttons', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
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

    // Repeated steps clamp at the OSM zoom limit and the world floor,
    // like the gestures do.
    for (var i = 0; i < 10; i++) {
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
    }
    expect(cameraZoom(), 19.0);

    for (var i = 0; i < 20; i++) {
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pump();
    }
    expect(cameraZoom(), 3.0);
  });

  testWidgets('the control pill hugs the configured screen edge', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    await TrackStore(root).saveZoomSliderSide('left');
    final model = await createModel(root);
    expect(model.zoomSliderSide, 'left');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    Positioned pillOf() => tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(const ValueKey('control-pill')),
        matching: find.byType(Positioned),
      ),
    );

    expect(pillOf().left, 12, reason: 'setting says left edge');
    expect(pillOf().right, isNull);

    await model.setZoomSliderSide('right');
    await tester.pump();
    expect(pillOf().left, isNull);
    expect(pillOf().right, 12, reason: 'setting says right edge');
  });

  testWidgets('settings sheet picks the track color and control side', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // The trace-color control (it drives only the live recording trace
    // now — the fog aggregates color by palette) is present alongside its
    // sibling appearance control.
    expect(find.text('Trace color'), findsOneWidget);
    expect(find.text('Control side'), findsOneWidget);
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Right'), findsOneWidget);

    // A trace tint pick persists in the index... (the About card's GitHub
    // link row grew the sheet; the swatch can land below the fold).
    await tester.ensureVisible(find.byTooltip('Blue'));
    await tester.pump();
    await tester.tap(find.byTooltip('Blue'));
    await tester.pump();
    expect(model.recordingTint, 'blue');
    final reloaded = TrackStore(root);
    await reloaded.load();
    expect(reloaded.recordingTint, 'blue');

    // So does a control-side switch (scrolled into view first — the sheet
    // grew past one screen when it gained the appearance controls).
    await tester.ensureVisible(find.text('Left'));
    await tester.pump();
    await tester.tap(find.text('Left'));
    await tester.pump();
    expect(model.zoomSliderSide, 'left');
  });

  testWidgets('settings sheet picks the theme and persists it', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
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

  testWidgets('switching to Dark theme resolves to dark brightness', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    // Set theme to dark
    await model.setThemeMode('dark');

    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    await tester.pump();

    // Verify the resolved theme brightness is dark by checking a widget in the tree
    final brightness = Theme.of(tester.element(find.byType(MapPage)))
        .brightness;
    expect(brightness, Brightness.dark);
  });

  testWidgets('unlocked road corridors render as translucent polylines', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    // Activate the synthetic road file and import the Main Street walk so
    // the track carries corridor unlock state.
    final roadFile = File(
      '${root.path}${Platform.pathSeparator}test_roads.unvisited-roads',
    );
    roadFile.writeAsBytesSync(fixture('test_roads.unvisited-roads'));
    model.setRoadFile(roadFile.path);
    final walk = File(
      '${root.path}${Platform.pathSeparator}main_street_walk.gpx',
    );
    walk.writeAsBytesSync(fixture('main_street_walk.gpx'));
    await model.importFromFile(walk.path);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
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

  testWidgets('a catalog without corridor state renders no polyline layer', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(fixture('morning_walk.gpx'));
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    expect(find.byType(PolylineLayer), findsNothing);
  });

  testWidgets('startup fit goes through the guarded initialCameraFit', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();

    final emptyModel = AppModel(TrackStore(root));
    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          model: emptyModel,
          cacheDir: cache,
          versionFuture: Future.value('2026-11-12 12:00'),
        ),
      ),
    );
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
    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          model: model,
          cacheDir: cache,
          versionFuture: Future.value('2026-11-12 12:00'),
        ),
      ),
    );
    expect(
      tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .options
          .initialCameraFit,
      isNotNull,
      reason: 'saved tracks: fit at startup via the engine-guarded path',
    );
  });

  testWidgets(
    'the follow-camera glides: rotation converges monotonically, no snap',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, lat: 52.5201, heading: 90, speed: 5.0);
      // Frame by frame: every step moves toward -90 (mod 360 = 270) through
      // the short arc and never more than a fraction of the remaining gap —
      // an instant move would jump the full 90° in the first frame.
      var prev = camera().rotation;
      var maxStep = 0.0;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final r = camera().rotation;
        final step = (nearestEquivalentRotation(r, prev) - prev).abs();
        maxStep = math.max(maxStep, step);
        // Monotone approach: the remaining gap never grows.
        final gapBefore =
            (nearestEquivalentRotation(-90, prev) - prev).abs();
        final gapAfter = (nearestEquivalentRotation(-90, r) - r).abs();
        expect(gapAfter, lessThanOrEqualTo(gapBefore + 1e-9));
        prev = r;
      }
      expect(maxStep, lessThan(30.0),
          reason: 'a single frame snapped most of the way to the course');
      expect(camera().rotation % 360, closeTo(270.0, 1.0));
    },
  );

  testWidgets(
    'the marker shows the course on screen while the camera eases in',
    (tester) async {
      // Regression: the marker used to be pinned screen-up in course mode,
      // so during the rotation easing (and after a released follow) the
      // nose pointed nowhere near the direction of travel.
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      await model.setMapRotation('course');
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;
      double markerAngle() {
        final m = tester
            .widget<Transform>(
              find.byKey(const ValueKey('recording-marker-rotate')),
            )
            .transform;
        return math.atan2(m.entry(1, 0), m.entry(0, 0));
      }

      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0, heading: 90);
      fakeFix(source, 1, lat: 52.5201, heading: 90);
      // Mid-glide (a few frames, not converged): the marker draws the
      // course in content space; the layer's camera rotation composes
      // with it on screen, so the widget angle itself is the course.
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final rotation = camera().rotation;
      expect(rotation, lessThan(-10.0));
      expect(rotation, greaterThan(-80.0));
      expect(
        markerAngle(),
        closeTo(math.pi / 2, 0.05),
      );
    },
  );

  testWidgets(
    'the recording marker mounts with the session\'s first fix',
    (tester) async {
      // Regression: the marker's subtree was keyed to MapPage.build, which
      // never re-runs for a fix — fixes notify only the recording-live
      // channel, while the session-start frame builds before the first
      // GPS fix exists. The marker never mounted, so on-device the icon
      // was gone for the whole ride. The other marker tests feed their
      // fixtures before the first pump, and the queued fixes flush into
      // the session as microtasks ahead of that frame's build — a harness
      // artifact this test rules out by settling the start frame first.
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      await model.startRecording(source: source, permissionGate: false);
      // The session-start frame: field timing — the notify-dirty page
      // builds while the session still has no fix (the first one lands
      // about a second after the record tap).
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recording-marker-disc')),
        findsNothing,
      );

      // The first fix per the real channel (not a build-time read): the
      // marker must come with the fix it reports.
      fakeFix(source, 0, lat: 52.5200, heading: 90, speed: 3.0);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byKey(const ValueKey('recording-marker-disc')),
        findsOneWidget,
      );
    },
  );

  testWidgets('the recording marker follows each fix, not the page build', (
    tester,
  ) async {
    // Regression: the marker's point was read once at MapPage.build and
    // captured in the per-fix builder's closure. An incidental model
    // notify mid-ride (a road overlay change, a settings write) mounted
    // the marker frozen at that fix; the follow-camera then glided on
    // with the live ones and the stale marker slid under the HUD and
    // off-screen — "the icon keeps disappearing".
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final source = FakePositionSource();

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();

    LatLng markerPoint() {
      final layer = tester.widget<MarkerLayer>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('recording-marker-disc')),
              matching: find.byType(MarkerLayer),
            )
            .first,
      );
      return layer.markers.single.point;
    }

    await model.startRecording(source: source, permissionGate: false);
    await tester.pump(); // The start frame, at field timing: no fix yet.
    fakeFix(source, 0, lat: 52.5200, heading: 0, speed: 2.0);
    await tester.pump(const Duration(seconds: 1));
    // Mount the marker the way a field device does mid-ride: any model
    // notify rebuilds the page. 'north' is chosen because it never arms
    // the compass stream in a widget test.
    await model.setMapRotation('north');
    await tester.pump();
    expect(markerPoint().latitude, closeTo(52.5200, 1e-9), reason: 'first fix');

    // Fix follows fix: the marker must ride along with each accepted one,
    // not stay pinned to whichever fix last coexisted with a page rebuild.
    for (var i = 1; i <= 5; i++) {
      fakeFix(source, i, lat: 52.5200 + i * 1e-4, heading: 0, speed: 2.0);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(
      markerPoint().latitude,
      closeTo(52.5200 + 5 * 1e-4, 1e-9),
      reason: 'the marker tracks the latest fix, not the mount-time one',
    );
  });

  testWidgets(
    'the top bar shows the session speed in its center',
    (tester) async {
      // The glanceable speed the rider wants: while recording the pill
      // carries Tracks, the live speed and Settings — mounted with the
      // session boundary, repainted per fix through the recording-live
      // channel alone (never read at toolbar build time — the
      // 2026-11-19 marker-mount lesson).
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      final segment = find.byKey(const ValueKey('recording-speed'));
      expect(segment, findsNothing); // Idle: no speed in the bar.

      await model.startRecording(source: source, permissionGate: false);
      await tester.pump(); // The start frame, field timing: no fix yet.
      expect(segment, findsOneWidget);
      expect(tester.widget<Text>(segment).data, '—');

      // The first fix is accepted but the speed is fused between two
      // fixes, so the number arrives with the second one — through the
      // per-fix channel; the caption names the unit.
      fakeFix(source, 0, lat: 52.5200, heading: 0, speed: 5.0);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(segment).data, '—');
      fakeFix(source, 1, prevLat: 52.5200, lat: 52.52005, heading: 0, speed: 5.0);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(segment).data, '18.0');
      expect(find.text('km/h'), findsOneWidget);

      // Between the two actions the bar keeps while recording, centered
      // in the pill (the pill itself centered on the map's top edge).
      final tracks = tester.getRect(find.byTooltip('Tracks'));
      final s = tester.getRect(segment);
      final settings = tester.getRect(find.byTooltip('Settings'));
      expect(
        s.left,
        greaterThan(tracks.right),
        reason: 'the speed segment rides right of Tracks',
      );
      expect(
        s.right,
        lessThan(settings.left),
        reason: 'the speed segment rides left of Settings',
      );
      final pill = tester.getRect(find.byType(FloatingToolbar));
      expect((s.center.dx - pill.center.dx).abs(), lessThan(2.0));
    },
  );

  testWidgets(
    'the recording toolbar fits the narrowest surface, panel open or not',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();

      await model.startRecording(source: source, permissionGate: false);
      // A brisk two-digit number is about the widest the segment gets;
      // pill = 48 + segment + 48 must still fit a 360 px surface. Two
      // fixes: the speed fuses between them.
      fakeFix(source, 0, lat: 52.5200, heading: 0, speed: 25.0);
      fakeFix(
        source,
        1,
        prevLat: 52.5200,
        lat: 52.52025,
        heading: 0,
        speed: 25.0,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('recording-speed')))
            .data,
        '90.0',
      );
      expect(tester.takeException(), isNull);

      // Toggling the stats panel never pushes the toolbar anywhere.
      await tester.tap(find.byKey(const ValueKey('recording-chip')));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  for (final surface in const [Size(411, 915), Size(411, 800), Size(360, 740)]) {
    testWidgets(
      'the marker clears the bottom column on $surface, panel open or not',
      (tester) async {
        // Regression: the follow-camera framed the fix at a fixed fraction
        // of the screen height, so on shorter screens (and with the stats
        // panel open) the marker rendered under the HUD cards — it read as
        // disappearing.
        await tester.binding.setSurfaceSize(surface);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final root = createRoot();
        final cache = createCache();
        final model = await createModel(root);
        await model.setMapRotation('course');
        final source = FakePositionSource();

        await pumpMapPage(
          tester,
          model: model,
          cache: cache,
          locationSupported: true,
        );
        await tester.pump();

        await model.startRecording(source: source, permissionGate: false);
        for (var i = 0; i < 5; i++) {
          fakeFix(source, i, lat: 52.5200 + i * 1e-4, heading: 90, speed: 2.0);
        }
        await tester.pump();
        await tester.pump();

        Rect rect(Key key) => tester.getRect(find.byKey(key));
        bool overlaps(Rect a, Rect b) => a.overlaps(b.deflate(1));

        void assertClear(String state) {
          final marker = rect(const ValueKey('recording-marker-disc'));
          expect(
            overlaps(marker, rect(const ValueKey('recording-chip'))),
            isFalse,
            reason: '$state: the marker sits under the chip',
          );
        }

        assertClear('panel closed');
        await tester.tap(find.byKey(const ValueKey('recording-chip')));
        await tester.pump();
        assertClear('panel open');
        expect(
          overlaps(
            rect(const ValueKey('recording-marker-disc')),
            rect(const ValueKey('stats-panel')),
          ),
          isFalse,
          reason: 'panel open: the marker sits under the stats panel',
        );
        // The chip row must fit the narrowest surface without overflowing.
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('the unvisited-roads chip is gated on road data', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    // Without a region the chip renders nothing (the widget stays in
    // the tree but paints no answer), whatever the camera sees.
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    expect(find.textContaining('Unvisited roads here'), findsNothing);

    // Activating a region is enough to show it — with the em dash
    // until a settled camera produces an answer.
    final roadFile = File(
      '${root.path}${Platform.pathSeparator}test_roads.unvisited-roads',
    );
    roadFile.writeAsBytesSync(fixture('test_roads.unvisited-roads'));
    final failure = await model.activateRoadFile(roadFile.path);
    expect(failure, isNull);
    await tester.pump();
    expect(find.byType(RoadCoverageChip), findsOneWidget);
    expect(find.textContaining('Unvisited roads here'), findsOneWidget);
  });

  testWidgets('the overlay toggle row is absent without a region', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Without a region there is nothing to toggle: no row.
    expect(find.text('Show unvisited roads'), findsNothing);
  });

  testWidgets('the overlay toggle switches the dashed layer off', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);
    final roadFile = File(
      '${root.path}${Platform.pathSeparator}test_roads.unvisited-roads',
    );
    roadFile.writeAsBytesSync(fixture('test_roads.unvisited-roads'));
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    expect(await model.activateRoadFile(roadFile.path), isNull);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(_dashedPolylines(tester), isNotEmpty, reason: 'on by default');

    await tester.tap(find.byTooltip('Settings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('Show unvisited roads'));
    await tester.pump();
    expect(find.text('Show unvisited roads'), findsOneWidget);

    final row = find.ancestor(
      of: find.text('Show unvisited roads'),
      matching: find.byType(ListTile),
    );
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(model.showUnvisitedRoads, isFalse);
    // The map below the sheet rebuilds: dashed roads and the chip both
    // go with the setting.
    expect(_dashedPolylines(tester), isEmpty);
    expect(find.textContaining('Unvisited roads here'), findsNothing);

    // Back on: the still-settled viewport restores both without a pan.
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(model.showUnvisitedRoads, isTrue);
    expect(_dashedPolylines(tester), isNotEmpty);
    expect(find.textContaining('Unvisited roads here'), findsOneWidget);
  });

  testWidgets('the unvisited-roads overlay dashes only with a region',
      (tester) async {
    final root = createRoot();
    final cache = createCache();
    final model = await createModel(root);

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );

    // No region: the settled Berlin start camera shows no dashed
    // roads at all.
    await tester.pump(const Duration(milliseconds: 400));
    expect(_dashedPolylines(tester), isEmpty);

    final roadFile = File(
      '${root.path}${Platform.pathSeparator}test_roads.unvisited-roads',
    );
    roadFile.writeAsBytesSync(fixture('test_roads.unvisited-roads'));
    expect(await model.activateRoadFile(roadFile.path), isNull);
    // Activation recomputes the still camera itself; the pump carries
    // the debounce-free async pass through.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    final dashed = _dashedPolylines(tester);
    expect(dashed, isNotEmpty,
        reason: 'the start camera covers the fixture streets');
    expect(dashed.first.pattern, isA<StrokePattern>());
    // All four fixture ways are dark with no walked tracks yet.
    expect(dashed.length, greaterThanOrEqualTo(4));
  });

  testWidgets('the camera action needs a location platform and a fix', (
    tester,
  ) async {
    // Desktop Linux: no location support, so the cluster (and the camera
    // with it) is not offered at all.
    final model = await createModel(createRoot(), FakePhotoSource());
    await pumpMapPage(
      tester,
      model: model,
      cache: createCache(),
      locationSupported: false,
    );
    await tester.pump();
    expect(find.byIcon(Icons.photo_camera_outlined), findsNothing);
    expect(find.byKey(const ValueKey('camera-button')), findsNothing);
  });

  testWidgets('the camera action appears once a real fix exists', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource();
    final model = await createModel(root, source);
    mockGeolocator(
      tester,
      permission: 3,
      // A fix that never arrives yet: the cluster is there (recording
      // waits too), the camera button is not.
      position: null,
    );

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('record-cluster')), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-button')), findsNothing,
        reason: 'no fix, nothing to tag a photo with');

    // The silent retry timer or a locate brings the fix in; here the
    // page's own locate action does, through the mocked channel.
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );
    await tester.tap(find.byTooltip('Center on current position'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('camera-button')), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets('the camera action saves a photo and says so', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(3)));
    final model = await createModel(root, source);
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('camera-button')));
    await tester.pump();
    await tester.pump();

    expect(source.captures, 1);
    expect(model.photos, hasLength(1));
    // The silent startup fix is what tags it: no second GPS request.
    expect(model.photos.single.lat, 52.5200);
    expect(model.photos.single.lon, 13.4050);
    expect(find.text('Photo added to the map'), findsOneWidget);
  });

  testWidgets('a declined capture says so and stores nothing', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(); // declined by default
    final model = await createModel(root, source);
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('camera-button')));
    await tester.pump();
    await tester.pump();

    expect(model.photos, isEmpty);
    expect(find.text('No photo taken'), findsOneWidget);
  });

  testWidgets('photo pins show on the map and open the preview on tap', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(11)));
    final model = await createModel(root, source);
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    // Off the map center: with an empty catalog the EmptyHint card sits
    // centered on screen and would swallow the pin's tap.
    final result = await model.takePhoto(
      const LatLng(52.54, 13.43),
      takenAt: DateTime.utc(2026, 11, 24, 9, 15),
    );
    final photo = (result as PhotoAdded).photo;
    await tester.pump();

    // The pin mounts off the model's catalog notification.
    expect(
      find.byKey(ValueKey('photo-marker-${photo.id}')),
      findsOneWidget,
    );

    await _tapMapAt(tester, const LatLng(52.54, 13.43));
    await tester.pump();
    await tester.pump();

    // The preview shows the stored image and the capture stamp.
    expect(find.byType(PhotoPreviewDialog), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Taken 2026-11-24'), findsOneWidget);
    expect(find.text('Save to gallery'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('the preview delete asks first, then removes the photo', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(12)));
    final model = await createModel(root, source);
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    final photo = (await model.takePhoto(const LatLng(52.54, 13.43),
            takenAt: DateTime.utc(2026, 11, 24)) as PhotoAdded)
        .photo;
    await tester.pump();

    await _tapMapAt(tester, const LatLng(52.54, 13.43));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('photo-delete')));
    await tester.pump();
    await tester.pump();

    // The two-step confirm is up; nothing is deleted yet.
    expect(model.photos, hasLength(1));
    expect(find.byKey(const ValueKey('photo-delete-confirm')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('photo-delete-confirm')));
    await tester.pump();
    await tester.pump();

    expect(model.photos, isEmpty);
    expect(model.store.photoFileFor(photo).existsSync(), isFalse);
    // The dialog closed with the deletion and the pin is gone.
    expect(find.byType(PhotoPreviewDialog), findsNothing);
    expect(find.byKey(ValueKey('photo-marker-${photo.id}')), findsNothing);
  });

  testWidgets('save to gallery reports its failure off-Android', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(13)));
    final model = await createModel(root, source);
    // The host channel has no native side in a widget test; without a
    // mock the invokeMethod future never completes in the fake-async zone.
    // Answer it the way a platform without a gallery would: an error.
    const host = MethodChannel('unvisited/host');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      host,
      (call) async => throw PlatformException(
        code: 'save_failed',
        message: 'no gallery host in tests',
      ),
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(host, null);
    });
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await model.takePhoto(const LatLng(52.54, 13.43),
        takenAt: DateTime.utc(2026, 11, 24));
    await tester.pump();

    await _tapMapAt(tester, const LatLng(52.54, 13.43));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('photo-save-to-gallery')));
    await tester.pump();
    await tester.pumpAndSettle();

    // No gallery host on the desktop/test platform: the toast says so,
    // the stored photo stays.
    expect(find.text('Could not save to the gallery'), findsOneWidget);
    expect(model.photos, hasLength(1));
  });

  testWidgets('the photos setting hides the camera button and the pins', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(16)));
    final model = await createModel(root, source);
    mockGeolocator(
      tester,
      permission: 3,
      position: {'lat': 52.5200, 'lon': 13.4050},
    );
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    await tester.pump();
    await tester.pump();
    await model.takePhoto(const LatLng(52.54, 13.43),
        takenAt: DateTime.utc(2026, 11, 24));
    await tester.pump();

    // On by default: button and pin are there.
    expect(find.byKey(const ValueKey('camera-button')), findsOneWidget);
    expect(
      find.byKey(ValueKey('photo-marker-${model.photos.single.id}')),
      findsOneWidget,
    );

    await model.setPhotosEnabled(false);
    await tester.pump();

    // Off: both hide, the stored photo stays.
    expect(find.byKey(const ValueKey('camera-button')), findsNothing);
    expect(
      find.byKey(ValueKey('photo-marker-${model.photos.single.id}')),
      findsNothing,
    );
    expect(model.photos, hasLength(1));

    // Back on: both return.
    await model.setPhotosEnabled(true);
    await tester.pump();
    expect(find.byKey(const ValueKey('camera-button')), findsOneWidget);
    expect(
      find.byKey(ValueKey('photo-marker-${model.photos.single.id}')),
      findsOneWidget,
    );
  });

  testWidgets('reposition arms tap-to-move and the next map tap lands the photo', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(14)));
    final model = await createModel(root, source);
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await model.takePhoto(const LatLng(52.54, 13.43),
        takenAt: DateTime.utc(2026, 11, 24));
    await tester.pump();

    // Preview -> Reposition: the dialog closes and the banner arms.
    await _tapMapAt(tester, const LatLng(52.54, 13.43));
    await tester.pump();
    await tester.pump();
    expect(find.byType(PhotoPreviewDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('photo-reposition')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(PhotoPreviewDialog), findsNothing);
    expect(find.byKey(const ValueKey('reposition-banner')), findsOneWidget);
    expect(
      find.text('Tap on the map where the photo was taken'),
      findsOneWidget,
    );

    // The next map tap moves the pin (and persists through the store).
    await _tapMapAt(tester, const LatLng(52.53, 13.44));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('reposition-banner')), findsNothing);
    expect(model.photos.single.lat, closeTo(52.53, 1e-9));
    expect(model.photos.single.lon, closeTo(13.44, 1e-9));
    final reopened = await createModel(root, source);
    expect(reopened.photos.single.lat, closeTo(52.53, 1e-9));
  });

  testWidgets('reposition cancel leaves the photo where it was', (tester) async {
    final root = createRoot();
    final cache = createCache();
    final source = FakePhotoSource(PhotoCaptureSucceeded(jpegBytes(15)));
    final model = await createModel(root, source);
    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await model.takePhoto(const LatLng(52.54, 13.43),
        takenAt: DateTime.utc(2026, 11, 24));
    await tester.pump();

    await _tapMapAt(tester, const LatLng(52.54, 13.43));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('photo-reposition')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('reposition-banner')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reposition-cancel')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('reposition-banner')), findsNothing);
    expect(model.photos.single.lat, closeTo(52.54, 1e-9));

    // With the mode cancelled, a map tap no longer repositions (it goes
    // back to aggregate selection, a no-op on an empty catalog).
    await _tapMapAt(tester, const LatLng(52.53, 13.44));
    await tester.pump();
    expect(model.photos.single.lat, closeTo(52.54, 1e-9));
  });
}

/// Taps the map at [latLng]'s screen position (photo pins open through
/// the map tap, not a marker-child gesture). The tap detector waits out
/// the double-tap window before firing onTap, so pump past it.
Future<void> _tapMapAt(WidgetTester tester, LatLng latLng) async {
  final camera = MapCamera.of(tester.element(find.byType(TileLayer)));
  final mapOrigin = tester.getTopLeft(find.byType(FlutterMap));
  await tester.tapAt(mapOrigin + camera.latLngToScreenOffset(latLng));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// The map's dashed (unvisited-roads) polylines - every other polyline
/// in the layers is a solid corridor or live trace.
List<Polyline> _dashedPolylines(WidgetTester tester) => [
      for (final layer
          in tester.widgetList<PolylineLayer>(find.byType(PolylineLayer)))
        for (final p in layer.polylines)
          if (p.pattern.segments != null) p,
    ];

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
class _TestWidgetsDelegate extends LocalizationsDelegate<WidgetsLocalizations> {
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

/// One walking fix per second north along the Greenwich meridian, ~11.1 m
/// between consecutive points.
/// Pumps the follow-camera's glide ticker to convergence: 50 ms fake-time
/// frames, ~4 s total ≈ 11 glide time constants, after which the camera
/// has settled and the ticker is idle.
/// The deliberate look-around while a follow-camera is armed (and
/// one-finger drags are peeks): two pointers dragged down together,
/// panning the map like a one-finger drag does elsewhere. Lives in
/// `helpers.dart` (shared with the playback tests).
Future<void> pumpGlide(WidgetTester tester, {int frames = 80}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// An eastward timed GPX with [n] points, 10 s apart — a replays-with-a-
/// timeline track around lat 45, lon 9 (the reposition-during-replay
/// test's fixture).
String eastwardTimedGpx(String name, int n) {
  final t0 = DateTime.utc(2026, 11, 13, 12);
  final points = [
    for (var i = 0; i < n; i++)
      '      <trkpt lat="45.0" lon="${(9.0 + i * 0.0004).toStringAsFixed(6)}">'
      '<time>${t0.add(Duration(seconds: 10 * i)).toIso8601String()}</time>'
      '</trkpt>',
  ];
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test">
  <trk><name>$name</name>
    <trkseg>
${points.join('\n')}
    </trkseg>
  </trk>
</gpx>
''';
}

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
  source.controller.add(
    PositionFix(
      lat: lat,
      lon: lon,
      time: DateTime.utc(2026, 11, 13, 12).add(Duration(seconds: second)),
      ele: ele,
      accuracy: acc,
      speed: speed,
      heading: heading,
    ),
  );
}

/// Matches a camera center against [expected] positionally: the released
/// follow-camera must leave the view where the user's pan put it.
Matcher sameCameraAs(LatLng expected) => predicate<LatLng>(
  (c) =>
      (c.latitude - expected.latitude).abs() < 1e-6 &&
      (c.longitude - expected.longitude).abs() < 1e-6,
  'camera stays at $expected',
);
