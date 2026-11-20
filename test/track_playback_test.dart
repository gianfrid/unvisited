import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/models/track.dart';
import 'package:unvisited/playback/track_playback.dart';

TrackPoint _p(double lat, double lon, DateTime? time) =>
    TrackPoint(lat: lat, lon: lon, time: time);

/// Three points ten seconds apart on a straight eastward line, plus the
/// start time they hang off — the timeline fixture of most tests below.
(LatLng, LatLng, LatLng, DateTime) _straightLine() {
  final start = DateTime.utc(2026, 1, 1, 10);
  const p0 = LatLng(45.0, 9.0);
  const p1 = LatLng(45.0, 9.00135); // ~1 arc-second east
  const p2 = LatLng(45.0, 9.0027); // ~2 arc-seconds east
  return (p0, p1, p2, start);
}

List<TrackPoint> _straightPoints() {
  final (p0, p1, p2, t0) = _straightLine();
  return [
    _p(p0.latitude, p0.longitude, t0),
    _p(p1.latitude, p1.longitude, t0.add(const Duration(seconds: 10))),
    _p(p2.latitude, p2.longitude, t0.add(const Duration(seconds: 20))),
  ];
}

void main() {
  test('tryBuild refuses tracks without a walkable timeline', () {
    final t = DateTime.utc(2026, 1, 1, 10);
    expect(TrackPlayback.tryBuild('', []), isNull);
    expect(TrackPlayback.tryBuild('', [_p(45, 9, t)]), isNull);
    expect(
      TrackPlayback.tryBuild(
        '',
        [_p(45, 9, null), _p(45.001, 9.001, null)],
      ),
      isNull,
    );
    // Equal timestamps never form a timeline either (a zero-long span).
    expect(
      TrackPlayback.tryBuild('', [_p(45, 9, t), _p(45.1, 9.1, t)]),
      isNull,
    );
  });

  test('tryBuild skips untimed points and drops time regressions', () {
    final (p0, p1, _, t0) = _straightLine();
    final playback = TrackPlayback.tryBuild(
      'test',
      [
        _p(p0.latitude, p0.longitude, null), // untimed: not on the line
        _p(p0.latitude, p0.longitude, t0),
        _p(
          p1.latitude,
          p1.longitude,
          t0.subtract(const Duration(seconds: 5)), // backwards: dropped
        ),
        _p(p1.latitude, p1.longitude, t0.add(const Duration(seconds: 10))),
      ],
    );
    expect(playback, isNotNull);
    expect(playback!.positions.length, 2);
    expect(playback.total, const Duration(seconds: 10));
  });

  test('starts playing, at the default speed, at the start', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    final (p0, _, _, _) = _straightLine();
    expect(playback.status, PlaybackStatus.playing);
    expect(playback.elapsed, Duration.zero);
    expect(playback.speed, 8);
    expect(playback.finished, false);
    expect(playback.position, p0);
  });

  test('advance scales the wall delta with the speed', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    playback.advance(const Duration(seconds: 2));
    expect(playback.elapsed, const Duration(seconds: 16));
  });

  test('advance is a no-op while paused', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    playback.pause();
    playback.advance(const Duration(seconds: 10));
    expect(playback.elapsed, Duration.zero);
    expect(playback.status, PlaybackStatus.paused);
  });

  test('position interpolates between the bridged points', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    playback.advance(const Duration(milliseconds: 625)); // 8x: 5 s timeline
    final (p0, p1, _, _) = _straightLine();
    expect(playback.position.latitude, closeTo(p0.latitude, 1e-12));
    expect(
      playback.position.longitude,
      closeTo((p0.longitude + p1.longitude) / 2, 1e-9),
    );
  });

  test('course points along the bridged gap', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    expect(playback.course, closeTo(90, 0.5));
    // And into the finish at the end: still eastward.
    playback.advance(const Duration(hours: 1));
    expect(playback.finished, true);
    expect(playback.course, closeTo(90, 0.5));
  });

  test('reaching the end clamps, pauses and lands on the last point', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    final (_, _, p2, _) = _straightLine();
    playback.advance(const Duration(hours: 1));
    expect(playback.elapsed, playback.total);
    expect(playback.status, PlaybackStatus.paused);
    expect(playback.finished, true);
    expect(playback.progressFraction, 1.0);
    expect(playback.position, p2);
  });

  test('play after the finish restarts from the beginning', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    playback.advance(const Duration(hours: 1));
    playback.play();
    expect(playback.status, PlaybackStatus.playing);
    expect(playback.elapsed, Duration.zero);
    expect(playback.finished, false);
    playback.advance(const Duration(seconds: 1)); // 8 s at the default
    expect(playback.elapsed, const Duration(seconds: 8));
  });

  test('restart rewinds paused, play resumes', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    playback.advance(const Duration(seconds: 1));
    playback.restart();
    expect(playback.elapsed, Duration.zero);
    expect(playback.status, PlaybackStatus.paused);
    playback.advance(const Duration(seconds: 1)); // paused: nothing
    expect(playback.elapsed, Duration.zero);
    playback.play();
    playback.advance(const Duration(seconds: 1));
    expect(playback.elapsed, const Duration(seconds: 8));
  });

  test('cycleSpeed walks the ladder and wraps', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    final start = playback.speed; // ladder rung 3 (8x) by default
    final walked = <double>[start];
    for (var i = 0; i < TrackPlayback.speedLadder.length; i++) {
      playback.cycleSpeed();
      walked.add(playback.speed);
    }
    final rotatedFrom = TrackPlayback.speedLadder.indexOf(start);
    expect(
      walked.take(TrackPlayback.speedLadder.length),
      TrackPlayback.speedLadder
          .skip(rotatedFrom)
          .followedBy(TrackPlayback.speedLadder.take(rotatedFrom)),
    );
    // ...and wraps back to the start rung after a full lap.
    expect(walked.last, start);
  });

  test('playedIndex trails the cursor without rewinding', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    expect(playback.playedIndex, 0);
    playback.advance(const Duration(seconds: 2)); // 16 s in: past point 1
    expect(playback.playedIndex, 1);
    playback.advance(const Duration(seconds: 2)); // 32 s in: the end
    expect(playback.playedIndex, 2);
    playback.restart();
    expect(playback.playedIndex, 0);
  });

  test('seekTo jumps forward and lands the cursor exactly', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    final (_, p1, _, _) = _straightLine();
    playback.seekTo(const Duration(seconds: 10));
    expect(playback.elapsed, const Duration(seconds: 10));
    expect(playback.playedIndex, 1);
    expect(playback.position, p1);
    expect(playback.progressFraction, 0.5);
    // Still playing: the next advance moves on from the seek point.
    playback.advance(const Duration(seconds: 1)); // 8 s at the default
    expect(playback.elapsed, const Duration(seconds: 18));
  });

  test('seekTo rewinds: the index is re-derived, not left stale', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    final (p0, p1, _, _) = _straightLine();
    playback.advance(const Duration(hours: 1)); // to the end
    expect(playback.playedIndex, 2);
    playback.seekTo(const Duration(seconds: 5)); // back between p0 and p1
    expect(playback.playedIndex, 0);
    expect(playback.position.latitude, closeTo(p0.latitude, 1e-12));
    expect(
      playback.position.longitude,
      closeTo((p0.longitude + p1.longitude) / 2, 1e-9),
    );
    expect(playback.course, closeTo(90, 0.5));
    expect(playback.finished, false);
  });

  test('seekTo clamps to the timeline ends', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    final (_, _, p2, _) = _straightLine();
    playback.seekTo(const Duration(days: 1));
    expect(playback.elapsed, playback.total);
    expect(playback.finished, true);
    expect(playback.position, p2);
    // The end is reached by seek, not by advance: still "playing" until
    // a tick clamps — but finished already reads true.
    expect(playback.status, PlaybackStatus.playing);
    playback.seekTo(const Duration(milliseconds: -1));
    expect(playback.elapsed, Duration.zero);
    expect(playback.finished, false);
    expect(playback.playedIndex, 0);
  });

  test('seekTo keeps the paused state', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    playback.pause();
    playback.seekTo(const Duration(seconds: 12));
    expect(playback.elapsed, const Duration(seconds: 12));
    expect(playback.status, PlaybackStatus.paused);
    playback.advance(const Duration(seconds: 10));
    expect(playback.elapsed, const Duration(seconds: 12));
  });

  test('play after a seek to the end restarts from the beginning', () {
    final playback = TrackPlayback.tryBuild('test', _straightPoints())!;
    playback.seekTo(playback.total);
    expect(playback.finished, true);
    playback.play();
    expect(playback.status, PlaybackStatus.playing);
    expect(playback.elapsed, Duration.zero);
  });

  test('a GPS pause interpolates as a slow crawl, never a teleport', () {
    final t0 = DateTime.utc(2026, 1, 1, 10);
    const west = LatLng(45.0, 9.0);
    const east = LatLng(45.0, 9.00405);
    final playback = TrackPlayback.tryBuild(
      'test',
      [
        _p(west.latitude, west.longitude, t0),
        // A ten-minute "pause" between two points.
        _p(east.latitude, east.longitude, t0.add(const Duration(minutes: 10))),
      ],
    )!;
    // Halfway through the pause the marker sits at the midpoint — the
    // timeline plays the gap the way a media player plays silence.
    // (Halfway is 300 s of timeline; at the default 8x that is 37.5 s of
    // wall clock.)
    playback.advance(const Duration(milliseconds: 37500));
    expect(playback.elapsed, const Duration(seconds: 300));
    expect(
      playback.position.longitude,
      closeTo((west.longitude + east.longitude) / 2, 1e-3),
    );
  });
}
