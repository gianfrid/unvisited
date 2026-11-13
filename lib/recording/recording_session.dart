/// The recording engine: a pure-Dart state machine that consumes a
/// [PositionSource] and produces an incrementally written GPX file plus
/// live session statistics.
///
/// Pure Dart on purpose (SPEC's portability rule, as for the parsers): the
/// Android session, the dashboard and the unit tests all view recording
/// through one class, and no widget ever builds sentences from it.
library;

import 'dart:math' as math;

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
/// elapsed runs first to last accepted fix, and moving time accumulates
/// only intervals whose speed reaches [movingSpeed].
class RecordingSession {
  RecordingSession({
    required this.stage,
    this.maxAccuracy = 50,
    this.segmentGap = const Duration(seconds: 30),
    this.movingSpeed = 0.5,
  });

  final GpxStageWriter stage;

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
  Duration get elapsed => _lastFix == null || _firstFix == null
      ? Duration.zero
      : _lastFix!.difference(_firstFix!);
  DateTime? _firstFix;
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

  double? _lastLat;
  double? _lastLon;

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
    if (gap > segmentGap) stage.breakSegment();
    stage.appendPoint(lat: fix.lat, lon: fix.lon, time: fix.time, ele: fix.ele);

    if (!first) {
      final step = _haversine(_lastLat!, _lastLon!, fix.lat, fix.lon);
      _distance += step;
      final fused = (fix.speed != null && fix.speed! >= 0)
          ? fix.speed!
          : gap.inMilliseconds == 0
              ? 0.0
              : step / (gap.inMilliseconds / 1000);
      _currentSpeed = fused;
      if (fused >= movingSpeed) _movingMillis += gap.inMilliseconds;
    }
    if (first) _firstFix = fix.time;
    _lastFix = fix.time;
    _lastLat = fix.lat;
    _lastLon = fix.lon;
    _currentEle = fix.ele;
    _points++;
    return FixDisposition.accepted;
  }

  void _onFix(PositionFix fix) => processFix(fix);
}

const _earthRadius = 6371000.0;

/// Same formula `lib/models/track.dart` uses for import lengths, so a
/// recorded track's engine-measured distance agrees with the catalog's.
double _haversine(double lat1, double lon1, double lat2, double lon2) {
  final rad = math.pi / 180;
  final dLat = (lat2 - lat1) * rad;
  final dLon = (lon2 - lon1) * rad;
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadius * math.asin(math.sqrt(h));
}
