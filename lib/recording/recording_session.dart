/// The recording engine: a pure-Dart state machine that consumes a
/// [PositionSource] and produces an incrementally written GPX file plus
/// live session statistics.
///
/// Pure Dart on purpose (SPEC's portability rule, as for the parsers): the
/// Android session, the dashboard and the unit tests all view recording
/// through one class, and no widget ever builds sentences from it.
library;

import 'dart:async';

import 'package:latlong2/latlong.dart';

import '../debug_log.dart';
import '../geo.dart';
import 'position_source.dart';
import 'staging_gpx.dart';

/// Recording session lifecycle: idle → recording ⇄ paused → stopped.
enum RecordingState { idle, recording, paused, stopped }

/// What the session did with the last fix handed to it.
enum FixDisposition {
  accepted,
  rejectedAccuracy,
  rejectedStale,
  rejectedSpeed,
  ignored,
}

/// Consumes fixes from a [PositionSource] into a [GpxStageWriter] while
/// tracking the dashboard's statistics.
///
/// Filters, before anything is written:
/// - **accuracy**: fixes with a horizontal accuracy above [maxAccuracy]
///   meters are dropped — their error radius dwarfs the ~15 m unlock
///   circle they would paint.
/// - **staleness**: fixes whose timestamp is not newer than the previous
///   accepted one are dropped; `maxUpdateAge`-style wall-clock staleness
///   is the source's job (geolocator's `AndroidSettings`) — the engine
///   cannot judge age without a clock it does not own, but it guarantees
///   the track stays chronological regardless of what arrives.
/// - **fix loss**: a gap of more than [segmentGap] between consecutive
///   accepted fixes closes the `<trkseg>` — unrecorded time must not join
///   two far-apart points with a straight line.
/// - **speed outliers**: within a continuous segment, a fix whose implied
///   displacement speed is beyond [maxSpeedMps], or — once [speedWindow]
///   step speeds are on record — above the Hampel-style threshold
///   `max(median + speedMadK·1.4826·MAD, minSpeedThresholdMps)` of that
///   window (median/MAD, not mean/σ: the outlier must not move its own
///   yardstick), is dropped as an outlier. The floor keeps a standstill
///   (median = MAD = 0) from rejecting a legitimate start.
/// A **pause** closes the segment too; a **resume** opens a new one.
///
/// Statistics measure only what was recorded: distance is the haversine
/// sum within segments (a pause or fix loss is a jump, not distance),
/// and the elapsed timer accrues only gaps that stay inside a segment —
/// a paused minute ticks nowhere.
class RecordingSession {
  RecordingSession({
    required this.stage,
    this.onFix,
    this.maxAccuracy = 50,
    this.segmentGap = const Duration(seconds: 30),
    this.movingSpeed = 0.5,
    this.speedWindow = 9,
    this.speedMadK = 3.0,
    this.maxSpeedMps = 45,
    this.minSpeedThresholdMps = 12,
    this.recordDistanceMeters = 12,
    this.recordMaxAge = const Duration(seconds: 5),
  });

  final GpxStageWriter stage;

  /// Called with every delivered fix after the engine processed it — the
  /// dashboard's tick: the UI reads the stats below at that point, so
  /// what it shows is always the state of the last delivered fix.
  final void Function(PositionFix fix)? onFix;

  /// Horizontal accuracy above which a fix is dropped, in meters.
  final double maxAccuracy;

  /// Gap between accepted fixes that counts as lost fix (segment break).
  final Duration segmentGap;

  /// Displacement speed above which time between fixes counts as moving,
  /// in m/s.
  final double movingSpeed;

  /// Ring buffer of recent implied step speeds, in m/s; also the minimum
  /// sample count before the MAD test applies.
  final int speedWindow;

  /// Hampel multiplier: a step speed above `median + speedMadK·1.4826·MAD`
  /// of the window is an outlier.
  final double speedMadK;

  /// Absolute implied-speed cap in m/s — the backstop for cold starts and
  /// teleports, where the window is empty or polluted.
  final double maxSpeedMps;

  /// Floor for the MAD threshold in m/s, so a standstill window (median =
  /// MAD = 0) does not reject the first real movement.
  final double minSpeedThresholdMps;

  /// Minimum displacement from the last *staged* point for a fix to be
  /// staged, in meters. Distance-based thinning: the sensor's 1 Hz stream
  /// oversamples any track (a ride logs ~4× the points a wrist GPS at
  /// smart-recording cadence does, with the extra points at GPS-noise
  /// scale), so a fix is recorded only when it moves far enough from what
  /// is already down. The threshold is implicitly speed-adaptive in time
  /// (the time gap between staged points is roughly this distance over
  /// the speed) and bounds the spatial step — which is what the fog
  /// corridor needs: unlock circles are 15 m in radius, so consecutive
  /// staged points must stay under ~30 m apart for the corridor to stay
  /// continuous. 12 m + one 1 s sensor step keeps that bound at any speed
  /// a track is likely to be recorded at, where a fixed-time rule (4 s
  /// at 11 m/s = 44 m) would split it.
  final double recordDistanceMeters;

  /// Wall-clock cap on the gap between staged points: slow or stationary
  /// stretches still record a point on this cadence, so pauses and crawl
  /// speeds leave points in the file and the live trace keeps breathing.
  final Duration recordMaxAge;

  /// Recent accepted implied step speeds (oldest first), capped at
  /// [speedWindow]. Segment breaks and resumes do not feed it.
  final List<double> _recentSpeeds = [];

  RecordingState state = RecordingState.idle;

  double get distanceMeters => _distance;
  double _distance = 0;

  /// First to last accepted fix, i.e. the recording duration; the stream
  /// may start earlier than the first fix (GPS cold start).
  Duration get elapsed => Duration(milliseconds: _elapsedMillis.round());

  /// Accumulated accepted-fix gaps in milliseconds. A gap that crosses a
  /// segment break (a pause or a fix loss) spans unrecorded time and
  /// counts nowhere — same rule as the distance's "a pause or fix loss is
  /// a jump, not distance". Pausing therefore freezes the timer with no
  /// extra machinery: while paused nothing is accepted, nothing accrues.
  double _elapsedMillis = 0;

  DateTime? _lastFix;

  Duration get movingTime => Duration(milliseconds: _movingMillis.round());
  double _movingMillis = 0;

  /// Staged points, i.e. what the finalized GPX will contain — not the
  /// raw accepted-fix count, which the thinning below deliberately keeps
  /// smaller.
  int get pointCount => _points;
  int _points = 0;

  /// Speed fused from the fix's own report (when sane) and displacement
  /// over time otherwise; null while nothing is measured yet.
  double? get currentSpeed => _currentSpeed;
  double? _currentSpeed;

  double? get currentEle => _currentEle;
  double? _currentEle;

  /// Last accepted fix's latitude, for the follow-camera; null until one
  /// fix is accepted.
  double? get currentLat => _lastLat;

  /// Last accepted fix's longitude (see [currentLat]).
  double? get currentLon => _lastLon;

  /// The last accepted fix's course over ground in degrees clockwise from
  /// true north — the device's own heading when it reports one, else the
  /// bearing between the fixes it bridges, fix by fix. Null until a fix
  /// carries a heading or two fixes have been accepted: with one fix and
  /// no heading the engine cannot yet tell which way is forward. A fix
  /// below the moving speed updates nothing: while the user stands still
  /// the previous course is the best answer (see [processFix] — a
  /// standstill fix's reported heading is Android's "unknown" sentinel,
  /// not a bearing).
  double? get currentCourse => _currentCourse;
  double? _currentCourse;

  /// The device's own reported heading from the last accepted fix, kept
  /// separate from the bridged-bearing `currentCourse` (bug 1): a fix
  /// that carries a heading sets both to the same value, a fix that
  /// does not leaves `currentHeading` null while `currentCourse` falls
  /// back to the bearing between fixes — and a fix below the moving
  /// speed sets this null (and holds `currentCourse`) so a standstill
  /// never reports a fake bearing.
  double? get currentHeading => _currentHeading;
  double? _currentHeading;

  double? _lastLat;
  double? _lastLon;

  /// The last staged point's position and time: the thinning measures
  /// displacement and age from what is already recorded, not from the
  /// previous raw fix. Null until the first point is staged.
  double? _stagedLat;
  double? _stagedLon;
  DateTime? _stagedTime;

  /// The staged points so far, grouped exactly like the staged
  /// `<trkseg>`s — the live map trace draws these while a session runs,
  /// so map, stats and file can never disagree about what a point is.
  /// Read-only copy out; the engine owns the lists.
  List<List<LatLng>> get liveSegments => [
        for (final s in _liveSegments) List<LatLng>.of(s),
      ];
  final List<List<LatLng>> _liveSegments = [];

  /// Per-point timestamps matching [liveSegments] one to one — the live
  /// trace's age fade keys off these.
  List<List<DateTime>> get liveSegmentTimes => [
        for (final s in _liveTimes) List<DateTime>.of(s),
      ];
  final List<List<DateTime>> _liveTimes = [];

  /// Set by [pause]: the next accepted fix opens a fresh segment, so the
  /// trace matches the staged file's `<trkseg>` breaks one to one.
  bool _segmentOpen = true;

  /// The position stream's subscription. [stop] cancels it: no fix is
  /// processed after the stop, and on Android the cancellation tears
  /// geolocator's foreground service — and its ongoing notification —
  /// down with the session.
  StreamSubscription<PositionFix>? _subscription;

  /// Starts consuming [source]; fixes flow in as the stream produces
  /// them. Pauses, resumes and the eventual stop are the caller's calls.
  void start(PositionSource source) {
    if (state != RecordingState.idle) throw StateError('session already started');
    state = RecordingState.recording;
    _subscription = source.stream.listen(_onFix);
  }

  /// Pauses: closes the current `<trkseg>`; the paused stretch records
  /// nothing.
  void pause() {
    if (state != RecordingState.recording) {
      throw StateError('pause outside a running session');
    }
    state = RecordingState.paused;
    _flushSegmentEnd();
    stage.breakSegment();
    _segmentOpen = true;
  }

  /// Stages the last accepted fix when the thinning left it unstaged —
  /// called on segment breaks (pause, fix loss) so a segment always ends
  /// exactly at its last raw fix, never mid-jump: the next segment starts
  /// after unrecorded time, and the jump across it must not be folded
  /// into one point.
  void _flushSegmentEnd() {
    final t = _lastFix;
    if (t == null || _stagedTime == t) return; // nothing pending
    stage.appendPoint(
        lat: _lastLat!, lon: _lastLon!, time: t, ele: _currentEle);
    // The live trace mirrors the staged file one to one — the flushed
    // point lands in both or neither.
    _liveSegments.last.add(LatLng(_lastLat!, _lastLon!));
    _liveTimes.last.add(t);
    _stagedLat = _lastLat;
    _stagedLon = _lastLon;
    _stagedTime = t;
    _points++;
  }

  /// Resumes: the next accepted fix opens a new `<trkseg>`.
  void resume() {
    if (state != RecordingState.paused) {
      throw StateError('resume outside a pause');
    }
    state = RecordingState.recording;
  }

  /// Stops for good: cancels the position stream's subscription (so the
  /// source — geolocator's foreground service on Android — ends with the
  /// session and no fix is processed after this point), then finalizes
  /// the staged file and completes once the bytes are closed out — the
  /// accepted fixes' loss window ends here, and slice 2 awaits this
  /// before handing the file to the imports.
  Future<void> stop() async {
    state = RecordingState.stopped;
    await _subscription?.cancel();
    _subscription = null;
    await stage.finalize();
  }

  /// One fix through the filters; the stream subscription calls this.
  /// Paused sessions are silent: their fixes are neither accepted nor
  /// rejected — they return [FixDisposition.ignored] because they fall
  /// outside recording by definition.
  FixDisposition processFix(PositionFix fix) {
    if (state != RecordingState.recording) return FixDisposition.ignored;
    if (fix.accuracy != null && fix.accuracy! > maxAccuracy) {
      return FixDisposition.rejectedAccuracy;
    }
    if (_lastFix != null && !fix.time.isAfter(_lastFix!)) {
      return FixDisposition.rejectedStale;
    }
    final gap = _lastFix == null ? Duration.zero : fix.time.difference(_lastFix!);
    final first = _lastFix == null;
    final brokeSegment = !first && gap > segmentGap;
    // A pause arms a fresh segment: the gap bridging a resume spans
    // parked time and counts nowhere, whatever its length.
    final resumedAfterPause = !first && _segmentOpen;
    // Speed-outlier filter, inside a continuous segment only — across a
    // segment break or resume the gap spans unrecorded time and the
    // implied speed is meaningless.
    double? impliedSpeed;
    if (!first && !brokeSegment && !resumedAfterPause && gap.inMilliseconds > 0) {
      final step = haversineMeters(_lastLat!, _lastLon!, fix.lat, fix.lon);
      impliedSpeed = step / (gap.inMilliseconds / 1000);
      if (impliedSpeed > maxSpeedMps) return FixDisposition.rejectedSpeed;
      if (_recentSpeeds.length >= speedWindow &&
          impliedSpeed > _speedOutlierThreshold()) {
        return FixDisposition.rejectedSpeed;
      }
    }
    if (brokeSegment) {
      _flushSegmentEnd();
      stage.breakSegment();
    }
    final newSegment = _segmentOpen || brokeSegment;
    if (newSegment) {
      _liveSegments.add([]);
      _liveTimes.add([]);
      _segmentOpen = false;
    }
    // Distance thinning: a fix is staged when it starts a segment (its
    // endpoints anchor the corridor), or when it has moved far enough
    // from what is already recorded, or when too much time has passed
    // (slow and stationary stretches still leave points). Stats and
    // distance below run on every raw fix regardless.
    final stageIt = newSegment ||
        _stagedTime == null ||
        haversineMeters(_stagedLat!, _stagedLon!, fix.lat, fix.lon) >=
            recordDistanceMeters ||
        fix.time.difference(_stagedTime!) >= recordMaxAge;
    if (stageIt) {
      _liveSegments.last.add(LatLng(fix.lat, fix.lon));
      _liveTimes.last.add(fix.time);
      stage.appendPoint(lat: fix.lat, lon: fix.lon, time: fix.time, ele: fix.ele);
      _stagedLat = fix.lat;
      _stagedLon = fix.lon;
      _stagedTime = fix.time;
      _points++;
    }

    // Ground speed as the engine fuses it: the sensor's own value when it
    // reports one, else the displacement over the gap. A first fix has no
    // gap to bridge, so a speed-less source leaves it unknown — the
    // course logic below then falls back to trusting the heading.
    final sensorSpeed =
        (fix.speed != null && fix.speed! >= 0) ? fix.speed! : null;
    final fused = sensorSpeed ??
        (first
            ? null
            : gap.inMilliseconds == 0
                ? 0.0
                : haversineMeters(_lastLat!, _lastLon!, fix.lat, fix.lon) /
                    (gap.inMilliseconds / 1000));

    if (!first) {
      final step = haversineMeters(_lastLat!, _lastLon!, fix.lat, fix.lon);
      _distance += step;
      if (impliedSpeed != null) {
        _recentSpeeds.add(impliedSpeed);
        if (_recentSpeeds.length > speedWindow) _recentSpeeds.removeAt(0);
      }
      _currentSpeed = fused!;
      // Dead time (a pause or the gap over a broken segment) counts
      // nowhere: the timer does not tick the pause, and the resumed
      // stretch is not moving time for having been away.
      if (!brokeSegment && !resumedAfterPause) {
        _elapsedMillis += gap.inMilliseconds;
        if (fused >= movingSpeed) _movingMillis += gap.inMilliseconds;
      }
    }
    // Course over ground: a moving fix's device heading wins; otherwise
    // the bearing the fix's displacement bridges. A fix below the moving
    // speed updates neither: Android reports bearing 0.0 when it cannot
    // say — not null — so a standstill "heading" is an unknown sentinel
    // (never a real due-north course), and a bridge across a standstill
    // is a noise bearing between two nearly identical positions. The
    // last known course is the best answer until movement resumes. A
    // source whose fused speed is unknown keeps the legacy behavior —
    // the engine cannot judge a stream that reports no speed at all.
    if (fused == null || fused >= movingSpeed) {
      _currentCourse = fix.heading ??
          (first ? null : initialBearingDeg(_lastLat!, _lastLon!, fix.lat, fix.lon));
      _currentHeading = fix.heading;
    } else {
      _currentHeading = null;
    }
    _lastFix = fix.time;
    _lastLat = fix.lat;
    _lastLon = fix.lon;
    _currentEle = fix.ele;
    return FixDisposition.accepted;
  }

  /// Hampel-style outlier threshold over [_recentSpeeds]: the window median
  /// plus [speedMadK] scaled MADs, floored at [minSpeedThresholdMps].
  /// The median and MAD (not mean/σ) keep a single outlier from inflating
  /// its own threshold.
  double _speedOutlierThreshold() {
    final median = _median(_recentSpeeds);
    final mad = _median(_recentSpeeds.map((s) => (s - median).abs()).toList());
    final threshold = median + speedMadK * 1.4826 * mad;
    return threshold < minSpeedThresholdMps ? minSpeedThresholdMps : threshold;
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  void _onFix(PositionFix fix) {
    final verdict = processFix(fix);
    if (verdict == FixDisposition.accepted) {
      DebugLog.instance.info(
        'fix accepted: ${fix.lat.toStringAsFixed(6)},${fix.lon.toStringAsFixed(6)}'
        ' speed=${fix.speed?.toStringAsFixed(1)} heading=${fix.heading?.toStringAsFixed(0)}',
      );
    } else if (verdict != FixDisposition.ignored) {
      DebugLog.instance.warn('fix ${verdict.name}: ${fix.lat},${fix.lon}');
    }
    if (onFix != null) onFix!(fix);
  }
}
