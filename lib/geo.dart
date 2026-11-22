import 'dart:math' as math;

/// Shared geo math. Kept free of Flutter imports like the rest of the
/// parsing/storage core, so model, recording engine and any future Rust
/// seam agree on the same formulas.
///
/// The single source of the haversine the catalog (`models/track.dart`) and
/// the recording engine (`recording/recording_session.dart`) both measure
/// with, so a recorded track's engine-measured distance agrees with the
/// catalog's re-imported numbers.

const _earthRadius = 6371000.0;

/// Displacement speed at or above which time between two fixes counts as
/// moving, in m/s. Shared by the recording engine (its `movingSpeed` default)
/// and the catalog's imported-track moving time, so both agree on what
/// "moving" means.
const double movingSpeedMps = 0.5;

/// Gap between consecutive fixes/points that counts as a segment break
/// (pause or fix loss): the time across it accrues nowhere — it is a jump,
/// not recorded time. Shared by the recording engine's `segmentGap` default
/// and the imported-track moving time.
const Duration segmentBreakGap = Duration(seconds: 30);

/// Great-circle distance in meters between two WGS84 points (spherical
/// haversine with the same earth radius the catalog lengths have always
/// used).
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  final rad = math.pi / 180;
  final dLat = (lat2 - lat1) * rad;
  final dLon = (lon2 - lon1) * rad;
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadius * math.asin(math.sqrt(h));
}

/// Initial bearing from one point to the next, in degrees clockwise from
/// true north, normalized to [0, 360).
double initialBearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final rad = math.pi / 180;
  final y = math.sin((lon2 - lon1) * rad) * math.cos(lat2 * rad);
  final x = math.cos(lat1 * rad) * math.sin(lat2 * rad) -
      math.sin(lat1 * rad) * math.cos(lat2 * rad) * math.cos((lon2 - lon1) * rad);
  return (math.atan2(y, x) / rad + 360) % 360;
}
