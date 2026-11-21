/// The recording engine's location seam. Recording is an Android feature,
/// but the engine behind it must stay portable Dart: everything that
/// consumes or produces fixes (the session, the staging writer, the
/// widget tests) speaks this interface, so the geolocator-backed Android
/// source can be swapped for anything else — synthetic streams in tests,
/// a future Linux source — without touching the engine.
library;

/// One GPS fix as the recording engine sees it. Everything is optional
/// except position and timestamp because sources differ in what they
/// report; the engine degrades gracefully per field (see
/// [RecordingSession]).
class PositionFix {
  const PositionFix({
    required this.lat,
    required this.lon,
    required this.time,
    this.ele,
    this.accuracy,
    this.speed,
    this.heading,
  });

  final double lat;
  final double lon;

  /// Elevation in meters when the source reports it (GPS always does);
  /// null on sources without altitude. Datum note: on Android the value
  /// is MSL where the device provides it (see `AndroidPositionSource`'s
  /// `useMSLAltitude`), otherwise raw WGS84 ellipsoidal height — the
  /// engine and the stored GPX take it as-is (see README).
  final double? ele;

  /// Horizontal accuracy in meters; null when the source does not say.
  /// Fixes above the session's accuracy threshold are dropped — a fix
  /// whose error radius dwarfs the unlock diameter would paint fog the
  /// user never visited.
  final double? accuracy;

  /// Ground speed in m/s when the source reports it (fused sensor value
  /// on Android); null falls back to displacement/time between fixes.
  final double? speed;

  /// Heading in degrees clockwise from true north, or null.
  final double? heading;

  /// When the fix was taken (UTC; GPS timestamps are), not when it was
  /// received. Monotonicity against previous fixes is the engine's
  /// staleness test.
  final DateTime time;
}

/// Produces fixes for one recording session. The Android implementation
/// wraps geolocator's `getPositionStream` with its foreground-service
/// settings; the widget tests and this slice's unit tests feed synthetic
/// streams. The engine treats whatever it gets as one chronological
/// stream and owns all filtering itself — a source must not need to know
/// the session's thresholds.
abstract class PositionSource {
  Stream<PositionFix> get stream;
}
