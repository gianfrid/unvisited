import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/import/track_importer.dart';
import 'package:unvisited/recording/position_source.dart';
import 'package:unvisited/recording/recording_session.dart';
import 'package:unvisited/recording/staging_gpx.dart';
import 'package:unvisited/storage/track_store.dart';

import 'helpers.dart';

/// Synthetic-stream tests for the recording engine (slice 1): filters,
/// segmenting, statistics and the GPX staging round-trip — including the
/// kill-mid-session salvage case. No emulator: fixes are fed by hand.

/// A fix stream the tests push through at will.
class FakeSource implements PositionSource {
  final controller = StreamController<PositionFix>();
  @override
  Stream<PositionFix> get stream => controller.stream;
}

void main() {
  final base = DateTime.utc(2026, 11, 13, 12);

  /// Walking north along the Greenwich meridian, ~11.1 m per 0.0001 deg
  /// of latitude (the re-import compares against TrackData's haversine).
  PositionFix fix(
    int second, {
    double lat = 52.5200,
    double lon = 13.4050,
    double? acc = 5,
    double? speed,
    double? heading,
    double? ele,
  }) =>
      PositionFix(
        lat: lat,
        lon: lon,
        time: base.add(Duration(seconds: second)),
        accuracy: acc,
        speed: speed,
        heading: heading,
        ele: ele,
      );

  RecordingSession newSession(String name) {
    final sink = MemoryStageSink();
    return RecordingSession(stage: GpxStageWriter(sink, name: name));
  }

  test('session moves through its state machine', () {
    final session = newSession('Test ride')..start(FakeSource());
    expect(session.state, RecordingState.recording);
    session.pause();
    expect(session.state, RecordingState.paused);
    session.resume();
    expect(session.state, RecordingState.recording);
    session.stop();
    expect(session.state, RecordingState.stopped);
    expect(() => session.pause(), throwsA(isA<StateError>()),
        reason: 'stop() must end the session for good');
  });

  test('accuracy rejections drop the fix entirely', () {
    final session = newSession('Accuracy')..start(FakeSource());
    expect(session.processFix(fix(0)), FixDisposition.accepted);
    expect(session.processFix(fix(1, acc: 49.9)), FixDisposition.accepted);
    expect(
        session.processFix(fix(3, acc: 50.1)), FixDisposition.rejectedAccuracy);
    expect(session.pointCount, 2);
    // A rejected fix must not advance the clock: had the session remembered
    // the bad fix's timestamp, this accurate one at t=2 (older than t=3,
    // newer than the last *accepted* fix at t=1) would be dropped as stale.
    expect(session.processFix(fix(2, lat: 52.52005)), FixDisposition.accepted);
    expect(session.pointCount, 3);
  });

  test('stale and out-of-order fixes are dropped', () {
    final session = newSession('Stale')..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(5));
    expect(session.processFix(fix(5)), FixDisposition.rejectedStale,
        reason: 'a duplicate timestamp is not a new fix');
    expect(session.processFix(fix(3)), FixDisposition.rejectedStale,
        reason: 'a rewind is not a new fix');
    expect(session.pointCount, 2);
  });

  test('jitter between close fixes accumulates as real distance', () {
    final session = newSession('Jitter')..start(FakeSource());
    // 0.0001 deg of latitude ~ 11.1 m in 1 s steps, i.e. ~11.1 m/s — the
    // fused haversine fallback, exercised with fix.speed absent.
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201));
    session.processFix(fix(2, lat: 52.5202, acc: 4));
    expect(session.pointCount, 3);
    expect(session.distanceMeters, closeTo(22.2, 0.2));
    expect(session.elapsed, const Duration(seconds: 2));
    expect(session.currentSpeed, closeTo(11.1, 0.2),
        reason: 'fused fallback: displacement over time');
    expect(session.movingTime, const Duration(seconds: 2));
  });

  test('fix.speed is preferred when reported and sane', () {
    final session = newSession('Speed')..start(FakeSource());
    // 5.5 m in 1 s would be 5.5 m/s by displacement, but the fix says 0.4;
    // the fused value keeps the fix's own report when it is sane.
    session.processFix(fix(0, speed: 0.4));
    session.processFix(fix(1, lat: 52.52005, speed: 0.4));
    expect(session.currentSpeed, 0.4);
    // Below the moving threshold -> time does not count as moving.
    expect(session.movingTime, Duration.zero);
    expect(session.distanceMeters, closeTo(5.5, 0.2),
        reason: 'distance itself stays the haversine sum');
  });

  test('a pause spans no timer: elapsed and moving time freeze and resume', () {
    final session = newSession('Lunch stop')..start(FakeSource());
    // One second of riding (moving speed).
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201));
    expect(session.elapsed, const Duration(seconds: 1));
    expect(session.movingTime, const Duration(seconds: 1));

    session.pause();
    // No timer machinery to stop: nothing is accepted, nothing accrues —
    // the dashboard's readout must not tick while parked.
    expect(session.elapsed, const Duration(seconds: 1));
    session.processFix(fix(900)); // a paused fix: silently ignored

    session.resume();
    // The resumed fix's gap spans the pause: it contributed no run time
    // (the pause ticks nowhere); only the second after it counts.
    session.processFix(fix(901, lat: 52.5202));
    session.processFix(fix(902, lat: 52.5203));
    expect(session.elapsed, const Duration(seconds: 2),
        reason: 'the parked 900 s tick nowhere');
    expect(session.movingTime, const Duration(seconds: 2));
  });

  test('the timer freeze survives a second pause/resume', () {
    final session = newSession('Errands')..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201));
    session.pause();
    session.resume();
    // The resumed fix bridges the pause: dead time, only the next
    // second accrues.
    session.processFix(fix(600, lat: 52.5202));
    session.processFix(fix(601, lat: 52.5203));
    expect(session.elapsed, const Duration(seconds: 2));
    session.pause();
    session.resume();
    session.processFix(fix(1200, lat: 52.5204));
    session.processFix(fix(1201, lat: 52.5205));
    expect(session.elapsed, const Duration(seconds: 3));
  });

  test('a short pause also ticks nowhere: the 30 s segment gap hides it '
      'from the old guard, not from the timer', () {
    // The bug this fixes: a pause shorter than the segment gap fell
    // under the old `gap <= segmentGap` guard and its seconds leaked
    // into elapsed and moving time.
    final session = newSession('Coffee stop')..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201));
    expect(session.elapsed, const Duration(seconds: 1));
    session.pause();
    session.resume();
    // The resumed fix bridges a 5 s parked stretch: dead time, only the
    // second after it accrues.
    session.processFix(fix(6, lat: 52.5202));
    session.processFix(fix(7, lat: 52.5203));
    expect(session.elapsed, const Duration(seconds: 2),
        reason: 'the parked 5 s tick nowhere, despite staying under the '
            'segment gap');
    expect(session.movingTime, const Duration(seconds: 2));

    // A short pause mid-ride still excludes exactly the parked stretch.
    session.pause();
    session.resume();
    session.processFix(fix(12, lat: 52.5204));
    session.processFix(fix(13, lat: 52.5205));
    expect(session.elapsed, const Duration(seconds: 3),
        reason: 'each parked stretch of 5 s ticks nowhere');
    expect(session.movingTime, const Duration(seconds: 3));
  });

  test('fix loss and pause read the same to the timer', () {
    // A fix-loss gap also crosses a segment break: the dashboard's timer
    // counts only the recorded time, not the drop-out.
    final session = newSession('Tunnel')..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201));
    session.processFix(fix(400, lat: 52.5202));
    session.processFix(fix(401, lat: 52.5203));
    expect(session.elapsed, const Duration(seconds: 2));
    expect(session.movingTime, const Duration(seconds: 2));
  });

  test('the live trace mirrors the staged segments', () {
    final session = newSession('Trace')..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201));
    expect(session.liveSegments.length, 1);
    expect(session.liveSegments.single.length, 2);

    // A pause opens a fresh segment, like the staged <trkseg>.
    session.pause();
    session.resume();
    session.processFix(fix(60, lat: 52.5202));
    session.processFix(fix(61, lat: 52.5203));
    expect(session.liveSegments.length, 2,
        reason: 'the resumed fix starts a new segment');

    // A fix-loss gap splits it too.
    session.processFix(fix(400, lat: 52.5204));
    expect(session.liveSegments.length, 3);
    expect(session.liveSegments.last.single.latitude, closeTo(52.5204, 1e-9));

    // Paused fixes add nothing.
    session.pause();
    session.processFix(fix(500, lat: 52.5299));
    expect(session.liveSegments.fold(0, (n, s) => n + s.length), 5);

    // The getter hands out copies: mutating it does not corrupt the engine.
    session.liveSegments.first.clear();
    expect(session.liveSegments.first.length, 2);
  });

  test('pause/resume breaks the track into two segments', () {
    final sink = MemoryStageSink();
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: 'Test ride'),
    )..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201));
    session.pause();
    expect(sink.buffer.toString(), contains('</trkseg>'),
        reason: 'pause closes the segment');
    final distanceAtPause = session.distanceMeters;
    // Fixes while paused: silently ignored, not rejected.
    session.processFix(fix(30));
    expect(session.pointCount, 2, reason: 'paused fixes record nothing');
    session.resume();
    // The resumed point joins the pre-pause last point (a pause is only a
    // segment break, as GPX consumers expect).
    session.processFix(fix(31, lat: 52.5202));
    session.processFix(fix(32, lat: 52.5203));
    expect(session.distanceMeters, closeTo(distanceAtPause + 22.2, 0.5));
    session.stop();
    final gpx = sink.buffer.toString();
    expect('<trkseg>'.allMatches(gpx).length, 2);
    expect('</trkseg>'.allMatches(gpx).length, 2,
        reason: 'stop finalizes the open one');
  });

  test('course is the fix heading when the device reports one', () {
    final session = newSession('Compass')..start(FakeSource());
    expect(session.currentCourse, isNull,
        reason: 'no heading-bearing fix has been accepted yet');
    expect(session.currentHeading, isNull);
    session.processFix(fix(0, heading: 170));
    expect(session.currentCourse, 170,
        reason: 'one heading-bearing fix is enough');
    expect(session.currentHeading, 170,
        reason: 'a fix that carries a heading sets both getters to it');
    // A subsequent fix without a heading falls back to the bearing.
    session.processFix(fix(1, lat: 52.5201, heading: null));
    expect(session.currentCourse, closeTo(0, 0.5),
        reason: 'bearing fallback: north along the meridian');
    expect(session.currentHeading, isNull,
        reason: 'a heading-less fix leaves currentHeading null');
  });

  test('course falls back to the bearing between fixes', () {
    final session = newSession('Bearing')..start(FakeSource());
    // The very first fix carries no heading: nothing is measured.
    expect(session.processFix(fix(0)), FixDisposition.accepted);
    expect(session.currentCourse, isNull);
    expect(session.currentHeading, isNull);
    // East along a parallel: the displacement's initial bearing.
    session.processFix(fix(1, lon: 13.405173));
    expect(session.currentCourse, closeTo(90, 0.5),
        reason: 'fused fallback: bearing between the fixes');
    expect(session.currentHeading, isNull,
        reason: 'currentHeading stays null; only currentCourse bridges');
  });

  test('a fix-loss gap closes the segment automatically', () {
    final sink = MemoryStageSink();
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: 'Gap ride'),
      segmentGap: const Duration(seconds: 30),
    )..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1));
    session.processFix(fix(100, lat: 52.5201)); // 99 s gap
    session.stop();
    final gpx = sink.buffer.toString();
    expect('<trkseg>'.allMatches(gpx).length, 2,
        reason: 'the gap broke the two fixes into a second segment');
    expect('</trkseg>'.allMatches(gpx).length, 2);
    expect(session.distanceMeters, closeTo(11.1, 0.2),
        reason: 'distance does not bridge the gap');
  });

  test('a full session finalizes valid GPX that re-imports', () async {
    final sink = MemoryStageSink();
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: 'Morning ride'),
    )..start(FakeSource());
    session.processFix(fix(0, ele: 42.5));
    session.processFix(fix(1, lat: 52.5201, ele: 43.0));
    await session.stop();

    final gpx = sink.buffer.toString();
    expect(gpx, startsWith('<?xml'));
    expect(gpx, contains('creator="unvisited"'));
    // Schema order: ele before time inside a point.
    final point = RegExp(r'<trkpt.*?</trkpt>', dotAll: true).firstMatch(gpx)!;
    expect(point.group(0)!.indexOf('<ele>'),
        lessThan(point.group(0)!.indexOf('<time>')));
    expect(gpx, endsWith('</gpx>\n'));
    expect(sink.closed, isTrue);
    expect(sink.flushes, greaterThan(0));
    expect(session.pointCount, 2);
    expect(session.elapsed, const Duration(seconds: 1));

    // The unified pipeline reads back exactly what was recorded.
    final data = TrackImporter().import(gpx.codeUnits, filename: 'staged.gpx');
    expect(data.format, 'GPX');
    expect(data.points, hasLength(2));
    expect(data.points.first.ele, closeTo(42.5, 0.01));
    expect(data.distanceMeters, closeTo(session.distanceMeters, 0.1));
  });

  test('kill between writes: salvage repairs the file and it re-imports', () {
    final sink = MemoryStageSink();
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: 'Killed ride'),
    )..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201, ele: 43.0));
    session.processFix(fix(2, lat: 52.5202, ele: 43.9));
    // The process dies after the last flushed point: complete points, an
    // open segment, none of the closing tags.
    final killed = sink.buffer
        .toString()
        .substring(0, sink.buffer.length - 1); // byte-level mid-newline cut

    final salvaged = salvageGpx(killed);
    expect(salvaged, isNotNull);
    final data =
        TrackImporter().import(salvaged!.codeUnits, filename: 'salvage.gpx');
    expect(data.format, 'GPX');
    expect(data.points, hasLength(3));
    expect(data.distanceMeters, closeTo(session.distanceMeters, 0.1));
  });

  test('kill mid-point: the half-written point is cut away', () {
    final sink = MemoryStageSink();
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: 'Killed ride'),
    )..start(FakeSource());
    session.processFix(fix(0));
    session.processFix(fix(1, lat: 52.5201, ele: 43.0));
    session.processFix(fix(2, lat: 52.5202, ele: 43.9));
    final text = sink.buffer.toString();
    // A real flush can cut the file midway through the next point's
    // markup: a point whose attributes were cut halfway through.
    final midPointCut = '${text.substring(0, text.lastIndexOf("</trkpt>"))}'
        '<trkpt lat="52.5203" lon="13.40';
    final salvaged = salvageGpx(midPointCut);
    expect(salvaged, isNotNull);
    final data =
        TrackImporter().import(salvaged!.codeUnits, filename: 'salvage.gpx');
    expect(data.points, hasLength(2),
        reason: 'the half-written point is cut, the flushed ones stay');
    expect(data.points.last.ele, closeTo(43.0, 0.01));
  });

  test('a kill before the first flushed point leaves nothing to salvage',
      () {
    expect(
        salvageGpx('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<gpx version="1.1" creator="unvisited"><trk><trkseg>'),
        isNull);
  });

  test('empty session (no fix ever accepted) finalizes nothing', () {
    final sink = MemoryStageSink();
    final session =
        RecordingSession(stage: GpxStageWriter(sink, name: 'Bare'));
    session.start(FakeSource());
    session.stop();
    expect(sink.buffer.toString(), isEmpty,
        reason: 'a session with no fix writes no file at all');
    expect(session.elapsed, Duration.zero);
  });

  group('renameGpxTrack (stop with name)', () {
    String stagedGpx(String trackName) {
      final sink = MemoryStageSink();
      final writer = GpxStageWriter(sink, name: trackName);
      writer.appendPoint(
          lat: 52.5200, lon: 13.4050, time: DateTime.utc(2026, 11, 14, 9));
      writer.finalize();
      return sink.buffer.toString();
    }

    test('the renamed file re-imports under the new name, points intact', () {
      final renamed = renameGpxTrack(stagedGpx('Rena'), 'Morning ride');
      final data = TrackImporter().import(renamed.codeUnits);
      expect(data.name, 'Morning ride');
      expect(data.points, hasLength(1));
    });

    test('escapes XML special characters in the new name', () {
      final renamed = renameGpxTrack(
          stagedGpx('Rena'), 'Ride & <test> "quoted"');
      expect(renamed,
          contains('<name>Ride &amp; &lt;test&gt; "quoted"</name>'));
    });

    test('a GPX without a name element passes through unchanged', () {
      final bare = stagedGpx('Rena').replaceFirst('<name>Rena</name>', '');
      expect(renameGpxTrack(bare, 'Morning ride'), bare);
    });

    test('the first name element only (the header trk name)', () {
      final gpx = stagedGpx('Rena');
      final renamed = renameGpxTrack(gpx, 'Morning ride');
      expect(renamed, isNot(contains('Rena')));
    });
  });


  test('the checked-in writer fixture re-imports (writer to reader)', () {
    // The fixture is produced by the stage writer itself
    // (tool/make_fixtures.dart): an app-shaped recording must satisfy the
    // unified pipeline's reader for as long as the writer exists.
    final data = TrackImporter().import(
      fixture('recorded_ride.gpx'),
      filename: 'recorded_ride.gpx',
    );
    expect(data.format, 'GPX');
    expect(data.name, 'Evening walk');
    expect(data.points, hasLength(5));
    // The catalog track's distance spans all 4 steps joined — unlike the
    // recording engine, which does not count distance across a trkseg
    // break (the pause), the importer joins the segments (4 × 11.1 m).
    expect(data.distanceMeters, closeTo(44.5, 0.3));
    expect(data.points.first.ele, closeTo(42.0, 0.01));
    expect(data.points.first.time, DateTime.parse('2024-05-01T18:00:00Z'));
    expect(data.points.last.ele, closeTo(44.5, 0.01));
  });

  test('the staged file lands under the requested path and re-imports',
      () async {
    // Real file variant of the writer, the way slice 2 wires it: the path
    // is the app root's recording/<timestamp>.gpx in production.
    final dir = Directory.systemTemp.createTempSync('unvisited-rec');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}1721000000.gpx');
    final sink = _FileSink(file);
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: 'File ride'),
    )..start(FakeSource());
    session.processFix(fix(0, ele: 42));
    session.processFix(fix(1, lat: 52.5201));
    session.stop();
    await sink.done;

    final bytes = file.readAsBytesSync();
    expect(bytes, isNotEmpty);
    final store = TrackStore(dir);
    final result = store.importBytes(bytes, filename: 'staged.gpx');
    expect(result.imported, isTrue, reason: 'outcome was ${result.outcome}');
    final stored = store.tracks.single;
    expect(stored.name, 'File ride',
        reason: 'recorder names survive the round-trip');
    expect(result.data!.points, hasLength(2));
  });
}

/// A [StageSink] over a real file. `dart:io` writes are buffered; the
/// flush and close futures are kept and awaited through [done] — in tests
/// by reading the file afterwards — because an un-awaited flush binds the
/// IOSink and a close arriving while it is bound throws.
class _FileSink implements StageSink {
  _FileSink(File file) : _iosink = file.openWrite();

  final IOSink _iosink;
  final List<Future<void>> _pending = [];

  @override
  void write(String s) {
    _iosink.write(s);
  }

  @override
  Future<void> flush() {
    final f = _iosink.flush();
    _pending.add(f);
    return f;
  }

  @override
  void close() {
    _pending.add(_iosink.close());
  }

  Future<void> get done => Future.wait(_pending);
}
