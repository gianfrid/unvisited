import 'dart:convert' show utf8;
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerScrollEvent;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/playback/track_playback.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';

import 'helpers.dart';

/// An eastward GPX with [n] points [step] apart in time, a fixed
/// ~0.0002° lon step per point: a timeline that walks due east at a
/// constant speed — the constant course makes the follow-camera's
/// rotation assertions exact.
String eastwardGpx(String name, int n,
    {Duration step = const Duration(seconds: 10)}) {
  final t0 = DateTime.utc(2026, 11, 13, 12);
  final points = [
    for (var i = 0; i < n; i++)
      '      <trkpt lat="45.0" lon="${(9.0 + i * 0.0002).toStringAsFixed(6)}">'
      '<time>${t0.add(step * i).toIso8601String()}</time></trkpt>',
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

/// A track without timestamps: no replay entry for it.
const untimedGpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test">
  <trk><name>untimed</name>
    <trkseg>
      <trkpt lat="45.0" lon="9.0"/>
      <trkpt lat="45.001" lon="9.001"/>
    </trkseg>
  </trk>
</gpx>
''';

/// Opens the drawer, then the first (most recent) track's ⋮ menu.
Future<void> openTrackMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Tracks'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byTooltip('Track actions').first);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('the track menu offers Playback, gated to timelines', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(untimedGpx));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await openTrackMenu(tester);

    // The untimed track's entry is visible but disabled — a shape is
    // not a timeline, and a control that can only fail is not offered.
    expect(find.text('Playback'), findsOneWidget);
    final item = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .firstWhere((i) => i.value == 'playback');
    expect(item.enabled, isFalse);
    // The enabled twin hides one drawer over: a timestamped track's
    // entry must be enabled (exercised end-to-end by the start test
    // below; here the gate's disabled side is the point).
  });

  testWidgets('the timed track menu entry is enabled and starts the replay', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 3)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await openTrackMenu(tester);
    final item = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .firstWhere((i) => i.value == 'playback');
    expect(item.enabled, isTrue);

    await tester.tap(find.text('Playback'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.playback, isNotNull);
  });

  testWidgets('starting the replay closes the drawer, mounts bar and marker', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await openTrackMenu(tester);
    await tester.tap(find.text('Playback'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.playback, isNotNull);
    expect(find.byKey(const ValueKey('playback-bar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playback-marker-disc')),
      findsOneWidget,
    );
    // The drawer closed behind the replay: its tiles are offstage.
    expect(find.byTooltip('Track actions'), findsNothing);
    // The bar shows the track, the timeline (the elapsed part advances
    // with the tick, so only the fixed total is deterministic) and the
    // default speed rung.
    expect(find.text('Morning walk'), findsOneWidget);
    expect(find.textContaining('/ 00:30'), findsOneWidget);
    expect(find.text('8×'), findsOneWidget);
  });

  testWidgets('the speed chip cycles the ladder, play pauses and resumes', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.playback!.status, PlaybackStatus.playing);
    expect(find.byIcon(Icons.pause), findsOneWidget);

    // The followed ladder: 8x -> 16x -> 32x.
    await tester.tap(find.byKey(const ValueKey('playback-speed')));
    await tester.pump();
    expect(find.text('16×'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playback-speed')));
    await tester.pump();
    expect(find.text('32×'), findsOneWidget);

    // Pause: the engine stops consuming deltas, the button flips.
    await tester.tap(find.byKey(const ValueKey('playback-play')));
    await tester.pump();
    expect(model.playback!.status, PlaybackStatus.paused);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    // Play again: the engine runs, the pause icon returns.
    await tester.tap(find.byKey(const ValueKey('playback-play')));
    await tester.pump();
    expect(model.playback!.status, PlaybackStatus.playing);
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('close stops the replay and clears bar, marker and trace', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('playback-bar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('playback-close')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(model.playback, isNull);
    expect(find.byKey(const ValueKey('playback-bar')), findsNothing);
    expect(
      find.byKey(const ValueKey('playback-marker-disc')),
      findsNothing,
    );
  });

  testWidgets('a replay hides the fog-of-war overlay, which returns on close', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    // One visible track, no selection: the only circle layer is the fog.
    final circles = tester
        .widget<CircleLayer>(find.byType(CircleLayer))
        .circles;
    expect(circles, isNotEmpty);

    model.startPlayback(model.tracks.single);
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.playback, isNotNull);
    // The replay rides the bare map: the fog circles are unmounted for
    // the replay's duration (the bar and marker mount as usual).
    expect(find.byType(CircleLayer), findsNothing);
    expect(find.byKey(const ValueKey('playback-bar')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('playback-marker-disc')),
      findsOneWidget,
    );

    // Closing the replay mounts the fog back, from the cached centers.
    await tester.tap(find.byKey(const ValueKey('playback-close')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.playback, isNull);
    expect(
      tester.widget<CircleLayer>(find.byType(CircleLayer)).circles,
      isNotEmpty,
    );
  });

  testWidgets('a session owns the map: starting it stops a running replay', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: true,
    );
    model.startPlayback(model.tracks.single);
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.playback, isNotNull);

    final source = FakePositionSource();
    await model.startRecording(source: source, permissionGate: false);
    await tester.pump(const Duration(milliseconds: 300));

    // The live session and a replay would fight over the follow-camera:
    // the replay yields with its bar and marker gone.
    expect(model.playback, isNull);
    expect(find.byKey(const ValueKey('playback-bar')), findsNothing);

    // And the menu no longer offers starting one mid-session.
    await openTrackMenu(tester);
    final item = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .firstWhere((i) => i.value == 'playback');
    expect(item.enabled, isFalse,
        reason: 'a running session owns the follow-camera');
  });

  testWidgets('course-up: the replay rides the follow-camera like a session', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 20)));
    await model.setMapRotation('course');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    await tester.pump();

    MapCamera camera() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera;
    double markerAngle() {
      final m = tester
          .widget<Transform>(find.byKey(const ValueKey('playback-marker-rotate')))
          .transform;
      return math.atan2(m.entry(1, 0), m.entry(0, 0));
    }

    model.startPlayback(model.tracks.single);
    // A few real ticks of the replay timer, then the frames the glide
    // needs: the fake clock fires the 50 ms tick timer on every pump,
    // the glide eases the camera toward each target.
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Course-up: the due-east course rotates the camera to -90 (east
    // points screen-up; flutter_map rotation is clockwise-positive).
    // The marker's own angle is the course alone in map-content space —
    // flutter_map renders layer children inside the camera's content
    // rotation, which supplies the camera term on screen — so the nose
    // nets to screen-up (course 90 + rotation 270), exactly what a
    // session's marker does at the same course.
    expect(camera().rotation % 360, closeTo(270.0, 1.0));
    expect(markerAngle(), closeTo(math.pi / 2, 0.05));

    // The marker sits framed below the vertical center (the follow lead),
    // east of the track's current point: the rotation turns the lead
    // toward screen-up too.
    final point = model.playback!.position;
    expect(camera().center.longitude, greaterThan(point.longitude));
    expect(camera().zoom, greaterThanOrEqualTo(17.0));
  });

  testWidgets('the scrubber seeks the timeline; the readout follows', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    // 4 points, 10 s apart: a 30 s timeline.
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    await tester.pump(const Duration(milliseconds: 300));
    // Pause so the replay timer's own advances can't race the scrub.
    await tester.tap(find.byKey(const ValueKey('playback-play')));
    await tester.pump();
    expect(model.playback!.status, PlaybackStatus.paused);

    final slider = find.byKey(const ValueKey('playback-scrubber'));
    expect(slider, findsOneWidget);

    // Scrub to the middle: the cursor jumps, the bar's readout follows.
    tester
        .widget<Slider>(slider)
        .onChanged!(0.5);
    await tester.pump();
    expect(model.playback!.elapsed, const Duration(seconds: 15));
    expect(find.text('00:15 / 00:30'), findsOneWidget);
    expect(tester.widget<Slider>(slider).value, 0.5);

    // And backwards: the rewind-capable seek lands before the start
    // clamp on the low end too.
    tester.widget<Slider>(slider).onChanged!(0.1);
    await tester.pump();
    expect(model.playback!.elapsed, const Duration(seconds: 3));
    expect(find.text('00:03 / 00:30'), findsOneWidget);

    tester.widget<Slider>(slider).onChanged!(2.0); // clamped to the end
    await tester.pump();
    expect(model.playback!.elapsed, const Duration(seconds: 30));
    expect(model.playback!.finished, isTrue);
    // The seek kept the paused state: no tick moved it on.
    expect(model.playback!.status, PlaybackStatus.paused);
  });

  testWidgets('the bar reads the timeline pace while playing, a dash paused', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    // 4 points 10 s apart, ~15.7 m of longitude apart: a constant
    // ~1.57 m/s — 5.7 km/h at every cursor, so the readout asserts a
    // value, whatever the pumped ticks advanced to.
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    await tester.pump(const Duration(milliseconds: 300));

    final readout = find.byKey(const ValueKey('playback-instant-speed'));
    expect(readout, findsOneWidget);
    expect(tester.widget<Text>(readout).data, '5.7 km/h');

    // Paused: the recording speed segment's dash convention — a
    // standing replay reads nothing.
    await tester.tap(find.byKey(const ValueKey('playback-play')));
    await tester.pump();
    expect(model.playback!.status, PlaybackStatus.paused);
    expect(tester.widget<Text>(readout).data, '—');

    // Playing again: the pace comes back live.
    await tester.tap(find.byKey(const ValueKey('playback-play')));
    await tester.pump();
    expect(model.playback!.status, PlaybackStatus.playing);
    expect(tester.widget<Text>(readout).data, '5.7 km/h');
  });

  testWidgets('a scrub keeps the follow-camera armed on the marker', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 20)));
    await model.setMapRotation('course');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    MapCamera camera() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera;

    model.startPlayback(model.tracks.single);
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(camera().rotation % 360, closeTo(270.0, 1.0));

    // Scrub to the middle of the timeline: the marker jumps, and the
    // follow — not released by the scrub — glides the camera to it.
    tester
        .widget<Slider>(find.byKey(const ValueKey('playback-scrubber')))
        .onChanged!(0.5);
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final point = model.playback!.position;
    expect(camera().rotation % 360, closeTo(270.0, 1.0));
    expect(
      (camera().center.latitude - point.latitude).abs(),
      lessThan(1e-3),
      reason: 'the follow stayed armed and rode the scrubbed marker',
    );
    expect(
      (camera().center.longitude - point.longitude).abs(),
      lessThan(1e-3),
    );
  });

  testWidgets('a gesture releases the replay follow, play re-arms it', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 20)));
    await model.setMapRotation('course');

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    MapCamera camera() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera;

    // A pan takes the camera (the follow released - exactly the
    // recording's release-on-gesture semantics).
    final size = tester.getSize(find.byType(FlutterMap));
    await tester.dragFrom(
      Offset(size.width / 2, size.height * 0.4),
      const Offset(0, 80),
    );
    final panned = camera().center;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      (camera().center.latitude - panned.latitude).abs() < 1e-6 &&
          (camera().center.longitude - panned.longitude).abs() < 1e-6,
      isTrue,
      reason: 'the released follow leaves the camera where the pan put it',
    );

    // The pause, then play: the play re-arms the follow, and the replay
    // takes the camera back with the next tick.
    await tester.tap(find.byKey(const ValueKey('playback-play')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('playback-play')));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(camera().rotation % 360, closeTo(270.0, 1.0));
    final point = model.playback!.position;
    expect(
      (camera().center.latitude - point.latitude).abs(),
      lessThan(1e-3),
      reason: 'the re-armed follow centers the marker again',
    );
  });

  testWidgets(
    'on a plugin-less platform the pill follow button re-arms the replay '
    'after a pan',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = AppModel(TrackStore(root));
      model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 30)));

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: false,
      );
      model.startPlayback(model.tracks.single);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;

      // No GPS locate on desktop — and while a replay runs the follow
      // camera is armed on the cursor, so the pill's last slot takes a
      // break entirely: nothing to re-center, the camera is already there.
      expect(find.byTooltip('Center on current position'), findsNothing);
      expect(find.byTooltip('Center on the replay cursor'), findsNothing);

      // A pan releases the follow: the camera stays where the pan put it,
      // and the pill's slot returns — the way back to the replay cursor.
      final size = tester.getSize(find.byType(FlutterMap));
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.4),
        const Offset(0, 120),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      final panned = camera().center;
      expect(
        (camera().center.latitude - panned.latitude).abs() < 1e-6 &&
            (camera().center.longitude - panned.longitude).abs() < 1e-6,
        isTrue,
        reason: 'the released follow leaves the camera where the pan put it',
      );
      final follow = find.byTooltip('Center on the replay cursor');
      expect(follow, findsOneWidget);

      // The follow button re-arms and re-centers on the replay cursor.
      await tester.tap(follow);
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final point = model.playback!.position;
      expect(
        (camera().center.latitude - point.latitude).abs(),
        lessThan(1e-3),
        reason: 'the follow button centers the replay marker again',
      );
      expect(
        (camera().center.longitude - point.longitude).abs(),
        lessThan(1e-3),
      );
      // Re-armed, the slot retires again.
      expect(find.byTooltip('Center on the replay cursor'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching to north mid-replay rotates the camera back to 0',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = AppModel(TrackStore(root));
      model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 20)));
      await model.setMapRotation('course');

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: false,
      );
      model.startPlayback(model.tracks.single);
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;
      // Course-up on an eastward track: rotation -90 == 270.
      expect(camera().rotation % 360, closeTo(270.0, 1.0));

      // The pill's rotation button toggles to north while a replay runs;
      // the follow then glides the rotation back to 0 on the next ticks.
      await tester.tap(find.byKey(const ValueKey('rotation-mode-button')));
      await tester.pump();
      expect(model.mapRotation, 'north');
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final r = camera().rotation % 360;
      expect(
        r < 1.0 || r > 359.0,
        isTrue,
        reason: 'north mode rotates the camera back to 0, got $r',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'course-up activation re-arms a released follow; north does not',
    (tester) async {
      final root = createRoot();
      final cache = createCache();
      final model = AppModel(TrackStore(root));
      model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 30)));
      await model.setMapRotation('course');

      await pumpMapPage(
        tester,
        model: model,
        cache: cache,
        locationSupported: false,
      );
      model.startPlayback(model.tracks.single);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      MapCamera camera() =>
          MapController.of(tester.element(find.byType(TileLayer))).camera;
      final rotationButton = find.byKey(const ValueKey('rotation-mode-button'));

      // A pan releases the follow (north mode by default).
      final size = tester.getSize(find.byType(FlutterMap));
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.4),
        const Offset(0, 120),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final panned = camera().center;

      // Starting from course-up: the tap goes to north — the map snaps
      // north on the spot, while the released camera stays where the pan
      // put it.
      await tester.tap(rotationButton);
      await tester.pump();
      expect(model.mapRotation, 'north');
      expect(
        camera().rotation % 360,
        lessThan(1.0),
        reason: 'north snaps the map north even with the follow released',
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        (camera().center.latitude - panned.latitude).abs() < 1e-6 &&
            (camera().center.longitude - panned.longitude).abs() < 1e-6,
        isTrue,
        reason: 'north does not re-arm: the center stays where the pan left it',
      );
      expect(
        camera().rotation % 360,
        lessThan(1.0),
        reason: 'the released follow leaves the north snap alone',
      );

      // Course: the same tap re-arms the follow and brings the camera back
      // to the replay cursor.
      await tester.tap(rotationButton);
      await tester.pump();
      expect(model.mapRotation, 'course');
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final point = model.playback!.position;
      expect(
        (camera().center.latitude - point.latitude).abs(),
        lessThan(1e-3),
        reason: 'course activation re-centers on the replay cursor',
      );
      expect(
        (camera().center.longitude - point.longitude).abs(),
        lessThan(1e-3),
      );
      expect(camera().rotation % 360, closeTo(270.0, 2.0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the bar fits the narrowest surface: scrubber keeps width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 4)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    await tester.pump(const Duration(milliseconds: 300));

    // Two rows inside one card: no overflow, a scrubber wide enough to
    // grab, the name present (elided, not zero-width).
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('playback-scrubber'))).width,
      greaterThan(100),
    );
    expect(find.text('Morning walk'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('playback-instant-speed')))
          .width,
      greaterThan(0),
    );
  });

  testWidgets('the lateral zoom slider holds its zoom during a replay', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 20)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    MapCamera camera() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera;
    expect(camera().zoom, greaterThanOrEqualTo(17.0)); // the floor

    // Step out to the world floor with the pill's zoom-out button: a
    // zoom-only programmatic move, the pill's signature. The armed follow
    // adopts it instead of walking the camera back to the floor on the
    // next ticks.
    for (var i = 0; i < 20; i++) {
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pump();
    }
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(camera().zoom, closeTo(3.0, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the scroll wheel releases the replay follow, zoom holds', (
    tester,
  ) async {
    final root = createRoot();
    final cache = createCache();
    final model = AppModel(TrackStore(root));
    model.store.importBytes(utf8.encode(eastwardGpx('Morning walk', 20)));

    await pumpMapPage(
      tester,
      model: model,
      cache: cache,
      locationSupported: false,
    );
    model.startPlayback(model.tracks.single);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    MapCamera camera() =>
        MapController.of(tester.element(find.byType(TileLayer))).camera;
    final before = camera().zoom;
    expect(before, greaterThanOrEqualTo(17.0));

    // Ten wheel notches out (flutter_map: newZoom = zoom - dy * 0.005):
    // the wheel is a camera-moving hand, so it releases the follow and
    // the zoom stays where the hand put it.
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
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final after = camera().zoom;
    expect(
      after,
      lessThan(before - 5),
      reason: 'the wheel zoomed out and the released follow did not walk it back',
    );
    expect(tester.takeException(), isNull);
  });
}
