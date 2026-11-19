import '../playback/track_playback.dart';
import '../storage/track_store.dart';
import 'playback_live.dart';

/// The playback concern of the app model: the replay of one stored
/// track — built from its timed points — and the per-tick repaint
/// channel the page's tick drives. Not a Listenable itself:
/// [onChanged] forwards *structural* notifications (a replay starting
/// or stopping mounts and unmounts map layers) to the owning
/// [AppModel]; per-tick repaints go to [playbackLive] only, so a
/// moving marker never rebuilds the fog overlay.
///
/// Everything ephemeral: a replay is presentation state over tracks the
/// catalog already owns — nothing about it persists, and the engine
/// owns no clock (the page ticks [TrackPlayback.advance]; a model must
/// never hold a timer no page listens to).
class PlaybackController {
  PlaybackController({required this.store, required this.onChanged});

  final TrackStore store;
  final void Function() onChanged;

  /// The running replay, or null. The map's layers and the playback bar
  /// read this through the model.
  TrackPlayback? _playback;
  TrackPlayback? get playback => _playback;

  /// The played track's id (the store's content-hash id), so a deleted
  /// track can stop its own replay (see [trackRemoved]).
  String? _trackId;

  /// The per-tick repaint channel: the page's replay tick notifies only
  /// this, so the bar, marker and trace rebuild without dragging the
  /// model-wide listeners along. Play/pause and speed changes fire it
  /// too — they are per-tick concerns of exactly those subtrees; the
  /// follow-camera re-arm reads the play state from the engine on the
  /// same channel.
  final playbackLive = PlaybackLiveState();

  /// Starts replaying [track], replacing any running replay (one at a
  /// time by design — two markers would fight over the follow-camera).
  /// Returns whether a replay started: a track whose points carry no
  /// walkable timeline never starts one — the track list disables its
  /// entry for those, this is the model-side guarantee — and a failed
  /// start leaves any running replay alone.
  bool start(StoredTrack track) {
    final data = store.loadPoints(track);
    final built = data == null
        ? null
        : TrackPlayback.tryBuild(track.name, data.points);
    if (built == null) return false;
    _playback = built;
    _trackId = track.id;
    onChanged();
    return true;
  }

  /// Stops the replay (the bar's close button).
  void stop() {
    if (_playback == null) return;
    _playback = null;
    _trackId = null;
    onChanged();
  }

  /// The catalog removed a track (delete is the only path): its replay
  /// stops with it — a marker replaying a track that no longer exists
  /// would be a ghost of deleted data.
  void trackRemoved(String id) {
    if (id == _trackId) stop();
  }

  void play() {
    _playback?.play();
    playbackLive.notify();
  }

  void pause() {
    _playback?.pause();
    playbackLive.notify();
  }

  void cycleSpeed() {
    _playback?.cycleSpeed();
    playbackLive.notify();
  }
}
