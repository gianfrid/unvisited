import '../geo.dart';

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

  /// Moving time in seconds: the sum of the gaps between consecutive
  /// timestamped points whose implied displacement speed reaches
  /// [movingSpeedMps]. A gap larger than [segmentBreakGap] is a segment
  /// break (pause or fix loss) and counts nowhere — a jump is not time,
  /// same rule as the distance's. A missing timestamp on either side
  /// breaks the chain. Null when the track carries no usable timestamps,
  /// like [durationSeconds].
  double? get movingSeconds {
    double total = 0;
    var any = false;
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      if (a.time == null || b.time == null) continue;
      final gap = b.time!.difference(a.time!);
      if (gap.isNegative) continue;
      any = true;
      if (gap > segmentBreakGap) continue;
      final gapSeconds = gap.inMilliseconds / 1000;
      if (gapSeconds <= 0) continue;
      final step = haversineMeters(a.lat, a.lon, b.lat, b.lon);
      if (step / gapSeconds >= movingSpeedMps) total += gapSeconds;
    }
    return any ? total : null;
  }

  /// Rough length in meters computed over consecutive points (haversine).
  double get distanceMeters {
    double total = 0;
    for (var i = 1; i < points.length; i++) {
      total += haversineMeters(
          points[i - 1].lat, points[i - 1].lon, points[i].lat, points[i].lon);
    }
    return total;
  }
}
