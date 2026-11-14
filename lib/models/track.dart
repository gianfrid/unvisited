import 'dart:math' as math;

/// Core track domain model. Kept free of Flutter imports so that import
/// parsing and storage remain unit-testable in plain Dart tests.

class TrackPoint {
  const TrackPoint({
    required this.lat,
    required this.lon,
    this.ele,
    this.time,
  });

  final double lat;
  final double lon;
  final double? ele; // meters, when the source format provides it
  final DateTime? time;
}

class TrackData {
  const TrackData({
    required this.name,
    required this.format,
    required this.points,
  });

  /// Human readable track name (falls back to the filename by convention).
  final String name;

  /// Source format: `GPX`, `FIT`, `KMZ` or `TCX`.
  final String format;

  final List<TrackPoint> points;

  bool get isEmpty => points.isEmpty;

  DateTime? get startTime {
    for (final p in points) {
      if (p.time != null) return p.time;
    }
    return null;
  }

  /// The last point carrying a timestamp, or null when none does.
  DateTime? get endTime {
    for (final p in points.reversed) {
      if (p.time != null) return p.time;
    }
    return null;
  }

  /// End minus start in seconds; null when the track carries no usable
  /// timestamps (both ends are needed) or the span is negative (corrupt).
  double? get durationSeconds {
    final start = startTime;
    final end = endTime;
    if (start == null || end == null) return null;
    final seconds = end.difference(start).inMilliseconds / 1000;
    return seconds < 0 ? null : seconds;
  }

  /// Rough length in meters computed over consecutive points (haversine).
  double get distanceMeters {
    double total = 0;
    for (var i = 1; i < points.length; i++) {
      total += _haversine(points[i - 1], points[i]);
    }
    return total;
  }
}

const _earthRadius = 6371000.0;

double _haversine(TrackPoint a, TrackPoint b) {
  final dLat = _rad(b.lat - a.lat);
  final dLon = _rad(b.lon - a.lon);
  final lat1 = _rad(a.lat);
  final lat2 = _rad(b.lat);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadius * math.asin(math.sqrt(h));
}

double _rad(double deg) => deg * (math.pi / 180);
