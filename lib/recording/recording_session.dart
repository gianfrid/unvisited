/// The recording engine: a pure-Dart state machine that consumes a
/// [PositionSource] and produces an incrementally written GPX file plus
/// live session statistics.
///
/// Pure Dart on purpose (SPEC's portability rule, as for the parsers): the
/// Android session, the dashboard and the unit tests all view recording
/// through one class, and no widget ever builds sentences from it.
library;

import 'package:latlong2/latlong.dart';

import '../geo.dart';
import 'position_source.dart';
import 'staging_gpx.dart';

/// Recording session lifecycle: idle → recording ⇄ paused → stopped.
enum RecordingState { idle, recording, paused, stopped }

/// What the session did with the last fix handed to it.
enum FixDisposition { accepted, rejectedAccuracy, rejectedStale }

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
  /// no heading the engine cannot yet tell which way is forward.
  double? get currentCourse => _currentCourse;
  double? _currentCourse;

  /// The device's own reported heading from the last accepted fix, kept
  /// separate from the bridged-bearing `currentCourse` (bug 1): a fix
  /// that carries a heading sets both to the same value, a fix that
  /// does not leaves `currentHeading` null while `currentCourse` falls
  /// back to the bearing between fixes.
  double? get currentHeading => _currentHeading;
  double? _currentHeading;

  double? _lastLat;
  double? _lastLon;

  /// The accepted fixes so far, grouped exactly like the staged
  /// `<trkseg>`s — the live map trace draws these while a session runs.
  /// Read-only copy out; the engine owns the lists.
  List<List<LatLng>> get liveSegments => [
        for (final s in _liveSegments) List<LatLng>.of(s),
      ];
  final List<List<LatLng>> _liveSegments = [];

  /// Set by [pause]: the next accepted fix opens a fresh segment, so the
  /// trace matches the staged file's `<trkseg>` breaks one to one.
  bool _segmentOpen = true;

  /// Starts consuming [source]; fixes flow in as the stream produces
  /// them. Pauses, resumes and the eventual stop are the caller's calls.
  void start(PositionSource source) {
    if (state != RecordingState.idle) throw StateError('session already started');
    state = RecordingState.recording;
    source.stream.listen(_onFix);
  }

  /// Pauses: closes the current `<trkseg>`; the paused stretch records
  /// nothing.
  void pause() {
    if (state != RecordingState.recording) {
      throw StateError('pause outside a running session');
    }
    state = RecordingState.paused;
    stage.breakSegment();
    _segmentOpen = true;
  }

  /// Resumes: the next accepted fix opens a new `<trkseg>`.
  void resume() {
    if (state != RecordingState.paused) {
      throw StateError('resume outside a pause');
    }
    state = RecordingState.recording;
  }

  /// Stops for good: finalizes the staged file and completes once the
  /// bytes are closed out — the accepted fixes' loss window ends here,
  /// and slice 2 awaits this before handing the file to the imports.
  Future<void> stop() {
    state = RecordingState.stopped;
    return stage.finalize();
  }

  /// One fix through the filters; the stream subscription calls this.
  /// Paused sessions are silent: their fixes are neither accepted nor
  /// rejected — they fall outside recording by definition.
  FixDisposition processFix(PositionFix fix) {
    if (state != RecordingState.recording) return FixDisposition.accepted;
    if (fix.accuracy != null && fix.accuracy! > maxAccuracy) {
      return FixDisposition.rejectedAccuracy;
    }
    if (_lastFix != null && !fix.time.isAfter(_lastFix!)) {
      return FixDisposition.rejectedStale;
    }
    final gap = _lastFix == null ? Duration.zero : fix.time.difference(_lastFix!);
    final first = _lastFix == null;
    final brokeSegment = !first && gap > segmentGap;
    if (brokeSegment) stage.breakSegment();
    if (_segmentOpen || brokeSegment) {
      _liveSegments.add([]);
      _segmentOpen = false;
    }
    _liveSegments.last.add(LatLng(fix.lat, fix.lon));
    stage.appendPoint(lat: fix.lat, lon: fix.lon, time: fix.time, ele: fix.ele);

    if (!first) {
      final step = haversineMeters(_lastLat!, _lastLon!, fix.lat, fix.lon);
      _distance += step;
      final fused = (fix.speed != null && fix.speed! >= 0)
          ? fix.speed!
          : gap.inMilliseconds == 0
              ? 0.0
              : step / (gap.inMilliseconds / 1000);
      _currentSpeed = fused;
      // Dead time (the gap over a broken segment) counts nowhere: the
      // timer does not tick the pause, and the resumed stretch is not
      // moving time for having been away.
      if (gap <= segmentGap) {
        _elapsedMillis += gap.inMilliseconds;
        if (fused >= movingSpeed) _movingMillis += gap.inMilliseconds;
      }
    }
    // Course over ground: the device's own heading wins; otherwise the
    // bearing the fix's displacement bridges. Computed before the last
    // fix is overwritten below.
    _currentCourse = fix.heading ??
        (first ? null : initialBearingDeg(_lastLat!, _lastLon!, fix.lat, fix.lon));
    _currentHeading = fix.heading;
    _lastFix = fix.time;
    _lastLat = fix.lat;
    _lastLon = fix.lon;
    _currentEle = fix.ele;
    _points++;
    return FixDisposition.accepted;
  }

  void _onFix(PositionFix fix) {
    processFix(fix);
    if (onFix != null) onFix!(fix);
  }
}
