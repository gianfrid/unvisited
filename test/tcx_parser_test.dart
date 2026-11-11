import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/import/track_parser.dart';
import 'package:unvisited/import/tcx_parser.dart';

import 'helpers.dart';

void main() {
  final parser = TcxParser();

  group('TcxParser', () {
    test('accepts TCX bytes', () {
      expect(parser.accepts(fixture('eiffel_ride.tcx')), isTrue);
      expect(parser.accepts(fixture('morning_walk.gpx')), isFalse);
    });

    test('parses points with time and altitude', () {
      final data =
          parser.parse(fixture('eiffel_ride.tcx'), sourceFilename: 'eiffel_ride.tcx');
      expect(data.format, 'TCX');
      expect(data.points.length, 3);
      final first = data.points.first;
      expect(first.lat, closeTo(48.85830, 1e-9));
      expect(first.lon, closeTo(2.29450, 1e-9));
      expect(first.ele, 33.0);
      expect(first.time, DateTime.parse('2024-05-01T08:00:00.000Z'));
      // filename beats the URL-ish <Id>
      expect(data.name, 'eiffel_ride');
    });

    test('uses <Id> as name when no filename is given', () {
      final data = parser.parse(fixture('eiffel_ride.tcx'));
      expect(data.name, DateTime.parse('2024-05-01T08:00:00.000Z').toIso8601String());
    });

    test('throws on TCX without trackpoints', () {
      const empty = '''
        <TrainingCenterDatabase
            xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities></Activities>
        </TrainingCenterDatabase>
      ''';
      expect(() => parser.parse(empty.codeUnits),
          throwsA(isA<TrackParseException>()));
    });
  });
}
