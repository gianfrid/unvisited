import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/import/gpx_parser.dart';
import 'package:unvisited/import/track_parser.dart';

import 'helpers.dart';

void main() {
  final parser = GpxParser();

  group('GpxParser.accepts', () {
    test('accepts GPX bytes', () {
      expect(parser.accepts(fixture('morning_walk.gpx')), isTrue);
    });

    test('rejects FIT and KMZ bytes', () {
      expect(parser.accepts(fixture('activity_ride.fit')), isFalse);
      expect(parser.accepts(fixture('afternoon_ride.kmz')), isFalse);
    });
  });

  group('GpxParser.parse', () {
    final data = parser.parse(fixture('morning_walk.gpx'),
        sourceFilename: 'morning_walk.gpx');

    test('parses name and format', () {
      expect(data.name, 'Morning walk');
      expect(data.format, 'GPX');
    });

    test('merges all segments into one point list', () {
      expect(data.points.length, 5);
    });

    test('parses lat/lon/ele/time', () {
      final first = data.points.first;
      expect(first.lat, closeTo(52.52000, 1e-9));
      expect(first.lon, closeTo(13.40500, 1e-9));
      expect(first.ele, 38.5);
      expect(first.time, DateTime.parse('2024-05-01T07:05:00Z'));
    });

    test('computes start time and distance', () {
      expect(data.startTime, DateTime.parse('2024-05-01T07:05:00Z'));
      // ~300m of walking; sanity bounds only, not exact math.
      expect(data.distanceMeters, inExclusiveRange(250, 400));
    });

    test('falls back to filename for name', () {
      final unnamed = parser.parse(fixture('morning_walk.gpx'),
          sourceFilename: 'some_dir/renamed.gpx');
      // fixture has <name>, so <name> wins; simulate missing name instead:
      final noNameXml = '''
        <gpx xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="1.0" lon="2.0"></trkpt>
          </trkseg></trk>
        </gpx>
      ''';
      final d = parser.parse(noNameXml.codeUnits, sourceFilename: 'x/renamed.gpx');
      expect(d.name, 'renamed');
      expect(unnamed.name, 'Morning walk');
    });

    test('throws on GPX without points', () {
      final empty = '<gpx xmlns="http://www.topografix.com/GPX/1/1"></gpx>';
      expect(
        () => parser.parse(empty.codeUnits),
        throwsA(isA<TrackParseException>()),
      );
    });
  });
}
