/// The playback engine: a pure-Dart timeline cursor that turns a stored
/// track's timed points into an animated replay.
///
/// Pure Dart on purpose (SPEC's portability rule, as for the parsers and
/// the recording engine): the page owns the tick that drives it (a model
/// must never hold a timer no page listens to), and every widget — the
/// marker, the trace, the playback bar — reads the same getters, so no
/// widget ever builds sentences from it either.
///
/// The engine holds no clock of its own: [advance] consumes a *wall* delta
/// from the host (capped there, so a backgrounded app doesn't jump
/// minutes) and moves the cursor along the track's *time* line by the
/// wall delta scaled with the playback [speed]. Points without timestamps
/// are skipped and time regressions dropped, so the timeline the cursor
/// walks is strictly increasing — source files may interleave what they
/// want.
library;

import '../geo.dart' show haversineMeters, initialBearingDeg;
import '../models/track.dart' show TrackPoint;
import 'package:latlong2/latlong.dart';

/// Playback state: [playing] consumes [TrackPlayback.advance] deltas,
/// [paused] ignores them. The end of the timeline pauses by itself (the
/// replay button restarts), so the finished readout never freezes at a
/// "playing" state that no longer moves.
enum PlaybackStatus { playing, paused }

/// A replay of one stored track: position and course interpolated along
/// the track's timeline, at a controllable speed.
class TrackPlayback {
  TrackPlayback._(this.positions, this.offsetsMs, this.name);

  /// Builds a playback from raw parsed points (as `TrackStore.loadPoints`
  /// hands them over), or null when the track cannot be replayed: no
  /// track without at least two points that carry strictly increasing
  /// timestamps has a timeline to walk. The track's display [name] rides
  /// along for the bar (a model class never builds sentences).
  static TrackPlayback? tryBuild(String name, List<TrackPoint> points) {
    final positions = <LatLng>[];
    final offsets = <int>[];
    DateTime? prev; // the last point kept, for the regression check
    DateTime? first; // the timeline's zero, for the absolute offsets
    for (final p in points) {
      final time = p.time;
      if (time == null) continue; // not on the timeline
      if (prev != null && !time.isAfter(prev)) continue; // regression
      first ??= time;
      offsets.add(time.difference(first).inMilliseconds);
      positions.add(LatLng(p.lat, p.lon));
      prev = time;
    }
    if (positions.length < 2) return null;
    return TrackPlayback._(positions, offsets, name);
  }

  /// The timed points' positions, in file order: the track the replay
  /// walks, and the shape the camera fit and the trace draw from.
  final List<LatLng> positions;

  /// Each position's offset from the first, in milliseconds — strictly
  /// increasing (the constructor dropped the rest).
  final List<int> offsetsMs;

  /// The track's display name, shown by the playback bar.
  final String name;

  /// The playback speed ladder, doubling: one tap on the speed chip steps
  /// to the next, wrapping around. 64x compresses an hour ride into a
  /// minute; 1x holds it at walking pace.
  static const speedLadder = <double>[1, 2, 4, 8, 16, 32, 64];

  /// The default ladder rung: 8x — a two-hour ride replays in fifteen
  /// minutes, quick enough to watch at one sitting.
  static const int _defaultSpeedIndex = 3;

  int _ladderIndex = _defaultSpeedIndex;

  /// The current playback speed (a multiplier: 8 means the timeline moves
  /// eight times faster than the wall clock).
  double get speed => speedLadder[_ladderIndex];

  /// Steps the speed to the next ladder rung, wrapping to the first.
  void cycleSpeed() {
    _ladderIndex = (_ladderIndex + 1) % speedLadder.length;
  }

  PlaybackStatus _status = PlaybackStatus.playing;

  /// Whether [advance] deltas currently move the cursor.
  PlaybackStatus get status => _status;

  int _progressMs = 0;

  /// How far along the track's timeline the cursor sits.
  Duration get elapsed => Duration(milliseconds: _progressMs);

  /// The track's full timeline span.
  Duration get total => Duration(milliseconds: offsetsMs.last);

  /// The cursor's fractional position along the timeline, 0.0 to 1.0.
  double get progressFraction =>
      total.inMilliseconds == 0 ? 0 : _progressMs / total.inMilliseconds;

  /// True once the cursor sits at the end of the timeline (reached by
  /// [advance] or [restart]ed away from by [play]).
  bool get finished => _progressMs >= offsetsMs.last;

  /// Plays: consumes [advance] deltas again. At the end of the timeline
  /// this restarts from the beginning — the replay button's behavior.
  void play() {
    if (finished) restart();
    _status = PlaybackStatus.playing;
  }

  /// Pauses: [advance] deltas stop moving the cursor.
  void pause() => _status = PlaybackStatus.paused;

  /// Rewinds to the start, paused. ([play] after this starts over.)
  void restart() {
    _progressMs = 0;
    _index = 0;
    _status = PlaybackStatus.paused;
  }

  /// Jumps the cursor to [position] on the timeline — the scrubber's
  /// seek — clamped to [0, total]. Unlike [advance] this moves both
  /// ways, so the cursor index is re-derived from scratch (a binary
  /// search over the strictly increasing [offsetsMs]; the forward-only
  /// walk in [_syncIndex] would leave a stale index after a rewind).
  /// The play state is kept: a playing replay continues from the new
  /// position, a paused one stays put. Seeking to the end lands on
  /// [finished]; seeking away from it clears it.
  void seekTo(Duration position) {
    _progressMs = position.inMilliseconds.clamp(0, offsetsMs.last).toInt();
    _index = _indexOfAtOrBefore(_progressMs);
  }

  /// The index of the last point at or before [progressMs] — binary
  /// search over [offsetsMs] (strictly increasing, first element 0).
  int _indexOfAtOrBefore(int progressMs) {
    var lo = 0;
    var hi = offsetsMs.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (offsetsMs[mid] <= progressMs) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Moves the cursor along the timeline by a wall-clock delta scaled
  /// with [speed], iff playing. Reaching the end clamps the cursor,
  /// pauses the playback and leaves the marker at the finish — a replay
  /// must never wrap or stop mid-air.
  void advance(Duration wallDelta) {
    if (_status != PlaybackStatus.playing) return;
    final scaled = wallDelta.inMilliseconds * speed;
    _progressMs = (scaled.isFinite
            ? (_progressMs + scaled).clamp(0, offsetsMs.last)
            : offsetsMs.last)
        .toInt();
    if (_progressMs >= offsetsMs.last) pause();
  }

  /// The cursor: the index of the last point at or before the current
  /// progress. Monotonic while the cursor walks forward; [restart] rewinds
  /// it.
  int _index = 0;

  /// The index of the last point at or before elapsed — the trace layer's
  /// played prefix ends here (then appends [position]).
  int get playedIndex {
    _syncIndex();
    return _index;
  }

  void _syncIndex() {
    while (_index + 1 < offsetsMs.length && offsetsMs[_index + 1] <= _progressMs) {
      _index++;
    }
  }

  /// The replayed position at the cursor: the actual point at the
  /// timeline's ends, linearly interpolated between the two points the
  /// cursor bridges elsewhere. A GPS pause in the source interpolates as
  /// a slow crawl between its bracketing points — the timeline plays it
  /// the way a media player plays a gap, never a teleport at 1x.
  LatLng get position {
    _syncIndex();
    if (_progressMs <= 0 || _index >= offsetsMs.length - 1) {
      // Before the first point or at/after the last: the ends themselves.
      return positions[_progressMs <= 0 ? 0 : positions.length - 1];
    }
    final span = offsetsMs[_index + 1] - offsetsMs[_index];
    final fraction = span <= 0
        ? 0.0
        : (_progressMs - offsetsMs[_index]) / span;
    final a = positions[_index];
    final b = positions[_index + 1];
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * fraction,
      a.longitude + (b.longitude - a.longitude) * fraction,
    );
  }

  /// The course of travel at the cursor in degrees clockwise from true
  /// north (the same [initialBearingDeg] the recording engine's bridged
  /// bearings use): the direction across the motion bracket, or into
  /// the rest of the track at the very ends. The seek has no stale-heading
  /// problem a live fix has — a timeline's direction is always known,
  /// except across a standstill's coincident bracket, which reads null.
  double? get course {
    if (positions.length < 2) return null;
    final (a, b) = _motionBracket();
    final from = positions[a];
    final to = positions[b];
    if (from.latitude == to.latitude && from.longitude == to.longitude) {
      return null;
    }
    return initialBearingDeg(
        from.latitude, from.longitude, to.latitude, to.longitude);
  }

  /// The instant speed at the cursor in meters per second: the
  /// timeline's own pace there — the haversine distance across the
  /// motion bracket over the time between its points (the same
  /// [haversineMeters] the catalog and the recording engine measure
  /// with). Never null on a timeline this engine agreed to walk — a
  /// standstill's coincident bracket reads 0, not a dash. The ladder's
  /// [speed] stays out of it: a replay walks the recorded pace at
  /// whatever wall-clock rate.
  double get instantSpeed {
    final (a, b) = _motionBracket();
    final from = positions[a];
    final to = positions[b];
    final meters = haversineMeters(
        from.latitude, from.longitude, to.latitude, to.longitude);
    return 1000 * meters / (offsetsMs[b] - offsetsMs[a]);
  }

  /// The cursor's motion bracket — the indices of the two points its
  /// motion is measured across, one ahead of the other: the points
  /// straddling the cursor, or the last segment's pair at the finish
  /// (nothing moves past the last point to be measured against).
  /// [course] and [instantSpeed] share it; only their metric across
  /// it differs.
  (int, int) _motionBracket() {
    _syncIndex();
    final b = finished ? positions.length - 1 : _index + 1;
    return (b - 1, b);
  }
}
