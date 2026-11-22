import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/models/track.dart';
import 'package:unvisited/storage/track_store.dart';

/// A point at [lat], [lon], [seconds] after the epoch base.
TrackPoint p(double lat, double lon, int seconds) => TrackPoint(
      lat: lat,
      lon: lon,
      time: DateTime.utc(2026, 1, 1, 10, 0, 0).add(Duration(seconds: seconds)),
    );

/// Points walking east at [mps] for [count] seconds, 1 s apart, starting at
/// [startSecond].
List<TrackPoint> walk(double mps, int count, int startSecond) => [
      for (var i = 0; i < count; i++)
        p(0, (startSecond + i) * mps / 111320.0, startSecond + i),
    ];

TrackData trackOf(List<TrackPoint> points) =>
    TrackData(name: 't', format: 'GPX', points: points);

/// Minimal GPX 1.1 with one segment and the given timestamped points.
String gpxOf(List<TrackPoint> points) {
  final pts = points.map((pt) {
    final t = pt.time!.toUtc().toIso8601String();
    return '    <trkpt lat="${pt.lat}" lon="${pt.lon}">'
        '<time>$t</time></trkpt>';
  }).join('\n');
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<gpx version="1.1" creator="test" '
      'xmlns="http://www.topografix.com/GPX/1/1">\n'
      ' <trk><name>t</name><trkseg>\n$pts\n </trkseg></trk>\n</gpx>\n';
}

void main() {
  group('TrackData.movingSeconds', () {
    test('stationary track: duration accrues, moving time is zero', () {
      final t = trackOf(walk(0, 10, 0));
      expect(t.durationSeconds, 9);
      expect(t.movingSeconds, 0);
    });

    test('continuously moving track: moving time equals the span', () {
      final t = trackOf(walk(2, 10, 0));
      expect(t.durationSeconds, 9);
      expect(t.movingSeconds, closeTo(9, 1e-9));
    });

    test('a gap over the segment-break threshold counts in the span but '
        'not in moving time', () {
      final t = trackOf([...walk(2, 10, 0), ...walk(2, 10, 69)]);
      // Span: 9 s + 60 s gap + 9 s. Moving: the two 9 s stretches only.
      expect(t.durationSeconds, 78);
      expect(t.movingSeconds, closeTo(18, 1e-9));
    });

    test('a gap at exactly the threshold is not a break and counts', () {
      final t = trackOf([...walk(2, 10, 0), ...walk(2, 10, 39)]);
      // Gap of 30 s is exactly segmentBreakGap: not a break, and at 2 m/s
      // implied it is moving — moving equals the whole 48 s span.
      expect(t.durationSeconds, 48);
      expect(t.movingSeconds, closeTo(48, 1e-9));
    });

    test('slow movement below the moving-speed threshold is not moving', () {
      final t = trackOf(walk(0.2, 10, 0)); // 0.2 m/s < movingSpeedMps
      expect(t.durationSeconds, 9);
      expect(t.movingSeconds, 0);
    });

    test('track without timestamps has no moving time', () {
      final t = TrackData(name: 't', format: 'GPX', points: [
        const TrackPoint(lat: 0, lon: 0),
        const TrackPoint(lat: 0, lon: 0.001),
      ]);
      expect(t.movingSeconds, isNull);
    });

    test('a single timestamped point has no gaps to judge: null', () {
      final t = trackOf([p(0, 0, 0)]);
      expect(t.movingSeconds, isNull);
    });

    test('missing timestamp on one side breaks the chain: with no '
        'consecutive timestamped pair there is no gap to judge, so null', () {
      final t = trackOf([
        p(0, 0, 0),
        const TrackPoint(lat: 0, lon: 0.001), // no time
        p(0, 0.002, 2),
      ]);
      expect(t.durationSeconds, 2); // the span still sees both ends
      expect(t.movingSeconds, isNull);
    });
  });

  group('TrackStore movingSeconds', () {
    late TrackStore store;
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('unvisited_moving');
      store = TrackStore(tmp);
      await store.load();
    });

    tearDown(() async {
      tmp.deleteSync(recursive: true);
    });

    test('import stores moving time next to the duration', () {
      final bytes = gpxOf([...walk(2, 10, 0), ...walk(2, 10, 69)])
          .codeUnits
          .toList();
      final r = store.importBytes(bytes, filename: 'ride.gpx');
      expect(r.imported, isTrue);
      expect(r.track!.durationSeconds, 78);
      expect(r.track!.movingSeconds, closeTo(18, 1e-9));
    });

    test('loadPoints heals a missing movingSeconds, never overwrites a set '
        'one', () {
      final bytes = gpxOf(walk(2, 10, 0)).codeUnits.toList();
      final r = store.importBytes(bytes, filename: 'ride.gpx');
      final track = r.track!;

      // Legacy index entry: field absent → healed on first open.
      track.movingSeconds = null;
      store.loadPoints(track);
      expect(track.movingSeconds, closeTo(9, 1e-9));

      // A set value is the record of what was true at import: not overwritten.
      track.movingSeconds = 123;
      store.loadPoints(track);
      expect(track.movingSeconds, 123);
    });
  });
}
