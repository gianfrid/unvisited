import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:unvisited/recording/position_source.dart' show PositionFix;
import 'package:unvisited/recording/recording_session.dart' show RecordingState;
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/tile_source.dart';
import 'package:unvisited/ui/app_model.dart';
import 'package:unvisited/ui/fog_of_war.dart';
import 'package:unvisited/ui/map_actions.dart';
import 'package:unvisited/ui/map_page.dart';
import 'package:unvisited/ui/recording_dashboard.dart';
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
    // space and attention) while Locate stays — its tap is the way back to
    // the follow after panning away. The slot reads Pause, with Stop above
    // it the whole session. The live speed is the primary readout, big and
    // bottom-center, from the engine's fix speed.
    expect(find.text('Import'), findsNothing);
    expect(find.text('Locate'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    final speedCard = find.byKey(const ValueKey('recording-speed'));
    expect(speedCard, findsOneWidget);
    expect(
      tester.getTopRight(speedCard).dy,
      greaterThan(tester.getBottomRight(find.byType(FlutterMap)).dy - 100),
      reason: 'the speed readout sits at the bottom of the map',
    );
    expect(find.text('10.8 km/h'), findsOneWidget);

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
    // The live speed is the primary readout — the big one below the map's
    // top chip, showing the fix's own 1 m/s — no longer a panel row. The
    // panel labels the averages, distance, both durations and the
    // altitude the fix reported.
    expect(find.text('Speed'), findsNothing);
    expect(find.text('3.6 km/h'), findsOneWidget);
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
      Offset(size.width / 2, size.height * 0.8),
      const Offset(0, 80),
    );
    await tester.pump();
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
      await model.setMapRotation('on');
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
      await tester.pump();
      await tester.pump();

      // Course-up: the east-heading fixes rotate the camera 90, and the
      // marker's own rotation nets to 0 — the nose points up on screen.
      expect(camera().rotation, closeTo(90.0, 0.1));
      expect(markerAngle(), closeTo(0.0, 1e-6));

      // A user pan releases the follow — and the rotation with it: the next
      // fix re-centers nothing and leaves the rotation where the pan put it.
      final size = tester.getSize(find.byType(FlutterMap));
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.8),
        const Offset(0, 80),
      );
      final panned = camera().center;
      fakeFix(source, 2, lat: 52.5202, heading: 180);
      await tester.pump();

      expect(
        camera().rotation,
        closeTo(90.0, 0.1),
        reason: 'the pan released the rotation with the follow',
      );
      expect(
        camera().center,
        sameCameraAs(panned),
        reason: 'the pan released the follow',
      );
      // The marker matches the new course against the camera's rotation, so
      // it still points along the course on screen.
      expect(markerAngle(), closeTo(math.pi / 2, 1e-6));
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
      await tester.pump();
      await tester.pump();

      // mapRotation defaults to off: the camera never rotates, but the
      // follow still centers on the fix and the marker still shows the
      // course (90° east against a north-up camera).
      expect(camera().rotation, closeTo(0.0, 0.1));
      expect(camera().center.latitude, closeTo(52.5201, 1e-6));
      expect(markerAngle(), closeTo(math.pi / 2, 1e-6));
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
    await tester.pump();
    await tester.pump();

    // A user pan releases the follow: the next fix stays where the pan put
    // it, and the toolbar keeps the Locate action to come back.
    final size = tester.getSize(find.byType(FlutterMap));
    await tester.dragFrom(
      Offset(size.width / 2, size.height * 0.8),
      const Offset(0, 80),
    );
    fakeFix(source, 2, lat: 52.5202);
    await tester.pump();
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
    await tester.pump();
    await tester.pump();
    expect(camera().center.latitude, closeTo(52.5203, 1e-6));
    expect(camera().zoom, closeTo(zoom, 1e-6));
  });

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
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(camera().center.latitude, closeTo(52.5200, 1e-6));
    // The follow armed on the attempt's success: the session's fix takes
    // the camera from here.
    fakeFix(source, 0, lat: 52.5201);
    await tester.pump();
    await tester.pump();
    expect(camera().center.latitude, closeTo(52.5201, 1e-6));
  });

  testWidgets(
    'locate and record live in the bottom-left stack, not the top bar',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = await createModel(root);
      final source = FakePositionSource();

      // GPS off at startup: no fix, so no Record — the stack is Locate only.
      mockGeolocator(tester, permission: 3, serviceEnabled: false);

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: true,
      );
      await tester.pump();
      await tester.pump();

      final mapRect = tester.getRect(find.byType(FlutterMap));
      Rect rectOf(String tooltip) => tester.getRect(find.byTooltip(tooltip));

      expect(find.text('Record'), findsNothing);
      final locate = rectOf('Center on current position');
      expect(
        locate.top,
        greaterThan(mapRect.height * 0.5),
        reason: 'locate sits in the bottom half of the map',
      );
      expect(locate.left, closeTo(12.0, 1.0));
      expect(
        mapRect.bottom - locate.bottom,
        closeTo(16.0, 1.0),
        reason: 'locate clears the bottom safe-area inset',
      );
      // The top bar is untouched: Import stays up there.
      expect(tester.getRect(find.text('Import')).top, lessThan(100));

      // A fix arrives through the locate tap: the Record button appears in
      // the slot directly above Locate.
      mockGeolocator(
        tester,
        permission: 3,
        position: {'lat': 52.5200, 'lon': 13.4050},
      );
      await tester.tap(find.byTooltip('Center on current position'));
      await tester.pump();
      await tester.pump();
      final record = rectOf('Record');
      final locateAfter = rectOf('Center on current position');
      expect(
        record.bottom,
        closeTo(locateAfter.top, 1.0),
        reason: 'record sits directly above locate',
      );
      expect(record.center.dx, closeTo(locateAfter.center.dx, 1.0));

      // While recording the slot holds Pause, still in the bottom-left
      // stack; the header keeps Tracks and Settings only.
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      await tester.pump();
      await tester.pump();
      expect(find.text('Record'), findsNothing);
      expect(
        find.text('Stop'),
        findsOneWidget,
        reason: 'stop is visible the whole session, running or paused',
      );
      final pause = rectOf('Pause');
      final locateRec = rectOf('Center on current position');
      expect(
        pause.bottom,
        closeTo(locateRec.top, 1.0),
        reason: 'pause occupies the record slot directly above locate',
      );

      // Paused: the slot reads Resume and Stop appears before it in the
      // stack, all still bottom-left.
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      final stop = rectOf('Stop');
      final resume = rectOf('Resume');
      final locatePaused = rectOf('Center on current position');
      expect(stop.top, greaterThan(mapRect.height * 0.5));
      expect(
        resume.bottom,
        closeTo(locatePaused.top, 1.0),
        reason: 'resume occupies the record slot directly above locate',
      );
      expect(
        stop.bottom,
        closeTo(resume.top, 1.0),
        reason: 'stop sits before the resume button in the stack',
      );
      expect(stop.center.dx, closeTo(resume.center.dx, 1.0));
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
    // The selection actions sit in a second pill below the toolbar, not
    // inside it.
    final toolbarTop = tester.getTopLeft(
      find.widgetWithText(FloatingToolbar, 'Tracks'),
    );
    final hideTop = tester.getTopLeft(
      find.byKey(const ValueKey('selection-hide')).first,
    );
    expect(hideTop.dy > toolbarTop.dy, isTrue);
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

  testWidgets(
    'toolbar, selection bar and recording chip stack in one top column',
    (tester) async {
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

      // Idle: neither the selection bar nor the recording chip.
      expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
      expect(find.byKey(const ValueKey('recording-chip')), findsNothing);

      // Select the aggregate (a map tap is owned by the recording UI once
      // a session runs, so set the selection directly), then start a
      // session: both bars must show, stacked in the column without
      // overlapping the toolbar or each other.
      model.selectedAnchor = model.aggregates.single.anchorId;
      model.notifyListeners();
      await tester.pump();
      await model.startRecording(source: source, permissionGate: false);
      fakeFix(source, 0);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-chip')), findsOneWidget);
      final toolbar = tester.getRect(
        find.widgetWithText(FloatingToolbar, 'Tracks'),
      );
      final selection = tester.getRect(
        find.byKey(const ValueKey('selection-bar')),
      );
      final chip = tester.getRect(
        find.byKey(const ValueKey('recording-chip')),
      );
      expect(selection.top, greaterThanOrEqualTo(toolbar.bottom));
      expect(chip.top, greaterThanOrEqualTo(selection.bottom));

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

  testWidgets('tapping a track tile selects and fits its aggregate', (
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

    // The startup camera fits both distant aggregates; tapping one tile
    // fits just that aggregate — a tighter zoom — and selects it.
    final before = zoom();
    await tester.tap(find.text('Morning walk'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.selectedAnchor, isNotNull);
    expect(
      model.selectedAggregate!.trackIds,
      contains(model.tracks.singleWhere((t) => t.name == 'Morning walk').id),
    );
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
    expect(
      zoom(),
      greaterThan(before),
      reason: 'fitting one aggregate zooms in over the Europe-wide fit',
    );
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
    expect(find.text('Cursore dello zoom'), findsOneWidget);
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
        .where((p) => p.color == recordingTraceColor('red'))
        .length;
    expect(tracePolylines(), 0);

    await model.startRecording(source: source, permissionGate: false);
    fakeFix(source, 0);
    fakeFix(source, 1, prevLat: 52.5200, lat: 52.5201);
    await tester.pump();
    await tester.pump();

    // While recording, one translucent recording-red polyline carries the
    // two accepted fixes — distinct from the catalog tint.
    expect(tracePolylines(), 1);
    final trace = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .singleWhere((p) => p.color == recordingTraceColor('red'));
    expect(trace.points.length, 2);

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

  testWidgets('lateral zoom slider steps and drags the camera zoom', (
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

    // Full upward rail drag tops out at the OSM zoom limit, downward at
    // the world floor; the clamps also apply to the header's old buttons.
    await tester.drag(
      find.byKey(const ValueKey('zoom-track')),
      const Offset(0, -400),
    );
    await tester.pump();
    expect(cameraZoom(), 19.0);

    await tester.drag(
      find.byKey(const ValueKey('zoom-track')),
      const Offset(0, 400),
    );
    await tester.pump();
    expect(cameraZoom(), 3.0);
  });

  testWidgets('zoom slider hugs the configured screen edge', (tester) async {
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

    Positioned sliderOf() => tester.widget<Positioned>(
      find.ancestor(
        of: find.byKey(const ValueKey('zoom-track')),
        matching: find.byType(Positioned),
      ),
    );

    expect(sliderOf().left, 12, reason: 'setting says left edge');
    expect(sliderOf().right, isNull);

    await model.setZoomSliderSide('right');
    await tester.pump();
    expect(sliderOf().left, isNull);
    expect(sliderOf().right, 12, reason: 'setting says right edge');
  });

  testWidgets('settings sheet picks the track color and slider side', (
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
    expect(find.text('Zoom slider'), findsOneWidget);
    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Right'), findsOneWidget);

    // A trace tint pick persists in the index...
    await tester.tap(find.byTooltip('Blue'));
    await tester.pump();
    expect(model.recordingTint, 'blue');
    final reloaded = TrackStore(root);
    await reloaded.load();
    expect(reloaded.recordingTint, 'blue');

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
