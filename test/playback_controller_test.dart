import 'dart:convert' show utf8;

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/playback/track_playback.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';

import 'helpers.dart';

/// A track shy of anything a replay needs: valid GPX geometry, no
/// timestamps at all.
const _untimedGpx = '''
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

void main() {
  test('starts the replay of a track with a walkable timeline', () {
    final model = AppModel(TrackStore(createRoot()));
    model.store.importBytes(fixture('morning_walk.gpx'));
    final track = model.tracks.single;
    expect(model.playback, isNull);
    expect(model.startPlayback(track), isTrue);
    expect(model.playback, isNotNull);
    expect(model.playback!.status, PlaybackStatus.playing);
    expect(model.playback!.name, track.name);
  });

  test('refuses a track without timestamps and leaves a replay running',
      () {
    final model = AppModel(TrackStore(createRoot()));
    // Points but no timestamps: no timeline to walk.
    model.store.importBytes(utf8.encode(_untimedGpx));
    final untimed = model.tracks.single;
    model.store.importBytes(fixture('morning_walk.gpx'));
    final timed = model.tracks.last;
    expect(model.startPlayback(timed), isTrue);
    final running = model.playback;
    expect(model.startPlayback(untimed), isFalse);
    // The failed start replaced nothing.
    expect(model.playback, same(running));
  });

  test('starting another track replaces the running replay', () {
    final model = AppModel(TrackStore(createRoot()));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('activity_ride.gpx'));
    expect(model.startPlayback(model.tracks.first), isTrue);
    final first = model.playback;
    expect(model.startPlayback(model.tracks.last), isTrue);
    expect(model.playback, isNot(same(first)));
    expect(model.playback!.name, model.tracks.last.name);
  });

  test('stop clears the replay', () {
    final model = AppModel(TrackStore(createRoot()));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.startPlayback(model.tracks.single);
    expect(model.playback, isNotNull);
    model.stopPlayback();
    expect(model.playback, isNull);
  });

  test('playbackLive fires on the per-tick concerns only', () {
    final model = AppModel(TrackStore(createRoot()));
    model.store.importBytes(fixture('morning_walk.gpx'));
    var modelNotifications = 0;
    model.addListener(() => modelNotifications++);
    var liveNotifications = 0;
    model.player.playbackLive.addListener(() => liveNotifications++);

    model.startPlayback(model.tracks.single);
    expect(modelNotifications, 1); // a structure change mounts layers

    model.player.pause();
    model.player.cycleSpeed();
    model.player.play();
    // Play/pause/speed never notify the model: fog and toolbar stay
    // still while the marker moves.
    expect(modelNotifications, 1);
    expect(liveNotifications, 3);

    model.stopPlayback();
    expect(modelNotifications, 2);
  });

  test('deleting the played track stops its replay', () async {
    final model = AppModel(TrackStore(createRoot()));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.store.importBytes(fixture('activity_ride.gpx'));
    model.startPlayback(model.tracks.first);
    // Deleting a different track leaves the replay alone.
    await model.delete(model.tracks.last);
    expect(model.playback, isNotNull);
    // Deleting the played one stops its replay — no ghost of deleted data.
    await model.delete(model.tracks.first);
    expect(model.playback, isNull);
    // And a clearing catalog ends any replay with it.
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.startPlayback(model.tracks.single);
    await model.deleteAll();
    expect(model.playback, isNull);
    expect(model.tracks, isEmpty);
  });

  test('seekTo moves the cursor and fires the per-tick channel only', () {
    final model = AppModel(TrackStore(createRoot()));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.startPlayback(model.tracks.single);
    var modelNotifications = 0;
    model.addListener(() => modelNotifications++);
    var liveNotifications = 0;
    model.player.playbackLive.addListener(() => liveNotifications++);

    final playback = model.playback!;
    model.player.seekTo(const Duration(seconds: 30));
    expect(playback.elapsed, const Duration(seconds: 30));
    // A seek is a per-tick concern like play/pause: no structural notify.
    expect(modelNotifications, 0);
    expect(liveNotifications, 1);
    // The play state survives the seek.
    expect(playback.status, PlaybackStatus.playing);
    // Seeking past the end lands on finished.
    model.player.seekTo(const Duration(days: 1));
    expect(playback.finished, isTrue);
    expect(playback.elapsed, playback.total);
  });

  test('reaching the end of a replay pauses by itself', () {
    final model = AppModel(TrackStore(createRoot()));
    model.store.importBytes(fixture('morning_walk.gpx'));
    model.startPlayback(model.tracks.single);
    model.player.playback!.advance(const Duration(hours: 2));
    expect(model.player.playback!.finished, isTrue);
    expect(model.player.playback!.status, PlaybackStatus.paused);
  });
}
