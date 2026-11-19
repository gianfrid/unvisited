import 'dart:convert' show utf8;
import 'dart:math' as math;

import 'package:flutter/material.dart';
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
    // points screen-up; flutter_map rotation is clockwise-positive),
    // and the marker's own rotation nets to 0 — the nose points up on
    // screen. Exactly what a session does at the same course.
    expect(camera().rotation % 360, closeTo(270.0, 1.0));
    expect(markerAngle(), closeTo(0.0, 0.05));

    // The marker sits framed below the vertical center (the follow lead),
    // east of the track's current point: the rotation turns the lead
    // toward screen-up too.
    final point = model.playback!.position;
    expect(camera().center.longitude, greaterThan(point.longitude));
    expect(camera().zoom, greaterThanOrEqualTo(17.0));
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
}
