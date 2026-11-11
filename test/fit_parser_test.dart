import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/import/fit_parser.dart';
import 'package:unvisited/import/track_parser.dart';

import 'helpers.dart';

void main() {
  final parser = FitParser();

  group('FitParser.accepts', () {
    test('keys off the .FIT magic, not the file extension', () {
      expect(parser.accepts(fixture('activity_ride.fit')), isTrue);
      // same bytes, wrong extension: still a FIT file
      expect(parser.accepts(fixture('activity_ride.fit')), isTrue);
      expect(parser.accepts(fixture('morning_walk.gpx')), isFalse);
      expect(parser.accepts([]), isFalse);
      expect(parser.accepts(List.filled(100, 0)), isFalse);
    });
  });

  group('activity FIT files', () {
    final data = parser.parse(fixture('activity_ride.fit'),
        sourceFilename: 'activity_ride.fit');

    test('parses semicircle coordinates to degrees', () {
      expect(data.format, 'FIT');
      expect(data.name, 'activity_ride');
      expect(data.points.length, 5); // 6 records, 1 without position
      final first = data.points.first;
      expect(first.lat, closeTo(52.52000, 1e-6));
      expect(first.lon, closeTo(13.40500, 1e-6));
    });

    test('decodes absolute and compressed timestamps', () {
      final times =
          data.points.map((p) => p.time).whereType<DateTime>().toList();
      expect(times, isNotEmpty);
      // all timestamps exist and are non-decreasing
      for (var i = 1; i < times.length; i++) {
        expect(!times[i].isBefore(times[i - 1]), isTrue,
            reason: 'timestamps must be non-decreasing');
      }
      expect(times.first, DateTime.parse('2024-05-01T08:00:00Z'));
    });

    test('drops records without a position (GPS loss / pause)', () {
      // the GPS-loss record (3rd in the fixture) must not yield a point
      expect(
        data.points
            .where((p) => p.lat == 52.52200 && p.lon == 13.40700)
            .isEmpty,
        isTrue,
      );
      // but later points survive it
      expect(data.points.last.lat, closeTo(52.52500, 1e-6));
    });
  });

  group('truncated FIT files (battery death mid-ride)', () {
    test('still delivers the points recorded before truncation', () {
      final data = parser.parse(fixture('truncated_ride.fit'),
          sourceFilename: 'truncated_ride.fit');
      expect(data.points.length, greaterThanOrEqualTo(3));
    });

    test('does not throw on a record cut in half', () {
      // Truncation mid-record is the nastiest case; the parser must keep
      // earlier points rather than failing the whole file.
      final bytes = fixture('activity_ride.fit');
      final cut5 = bytes.sublist(0, bytes.length - 5); // inside last record
      expect(() => parser.parse(cut5), returnsNormally);
      final afterCut = parser.parse(cut5);
      expect(afterCut.points.length, 4);
    });
  });

  group('monitoring FIT files (file id type 32)', () {
    test('are skipped, not imported', () {
      expect(
        () => parser.parse(fixture('monitoring.fit'),
            sourceFilename: 'GARMIN/Monitor/MY-DAILY-STATS.FIT'),
        throwsA(isA<UnsupportedTrackException>()),
      );
    });

    test('are detected by content, whatever the filename claims', () {
      // A monitoring file named like an activity must still be skipped.
      final monitoringBytes = fixture('monitoring.fit');
      expect(parser.accepts(monitoringBytes), isTrue);
      expect(
        () => parser.parse(monitoringBytes, sourceFilename: 'ride.fit'),
        throwsA(isA<UnsupportedTrackException>()),
      );
    });
  });

  test('non-activity, non-monitoring FIT types are refused too', () {
    final workout = <int>[
      0x0E, 0x10, 0xE1, 0x07, 0x1C, 0x00, 0x00, 0x00, //
      0x2E, 0x46, 0x49, 0x54,
      0x00, 0x00, // header crc
      // definition: local 0 / file_id: type field (6, size 1, enum)
      0x40, 0x00, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x00, //
      // data: local 0: type = 5 (workouts are not activities)
      0x00, 0x05, //
    ];
    expect(
      () => parser.parse(workout),
      throwsA(isA<UnsupportedTrackException>()),
    );
  });
}
