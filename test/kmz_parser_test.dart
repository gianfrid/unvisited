import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/import/kmz_parser.dart';
import 'package:unvisited/import/track_importer.dart';

import 'helpers.dart';

void main() {
  final parser = KmzParser();
  final kmlParser = KmlParser(parser);

  group('KmzParser', () {
    test('accepts ZIP magic, rejects XML and FIT', () {
      expect(parser.accepts(fixture('afternoon_ride.kmz')), isTrue);
      expect(parser.accepts(fixture('morning_walk.gpx')), isFalse);
      expect(parser.accepts(fixture('activity_ride.fit')), isFalse);
    });

    test('parses gx:Track with lon,lat coordinate order', () {
      final data = parser.parse(fixture('afternoon_ride.kmz'),
          sourceFilename: 'afternoon_ride.kmz');
      expect(data.format, 'KMZ');
      expect(data.name, 'Afternoon ride');
      expect(data.points.length, 3);
      // KML is longitude-first: sanity-check lon/lat weren't swapped.
      expect(data.points.first.lat, closeTo(52.52, 1e-9));
      expect(data.points.first.lon, closeTo(13.405, 1e-9));
      expect(data.points.first.time, DateTime.parse('2024-05-01T15:00:00.000Z'));
    });

    test('parses LineString coordinates blocks too', () {
      const kml = '''
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document><name>Line ride</name>
            <Placemark><name>Line ride</name>
              <LineString>
                <coordinates>13.40,52.52,41.0 13.41,52.53,42.0</coordinates>
              </LineString>
            </Placemark>
          </Document>
        </kml>
      ''';
      final points = parser.parseKml(kml);
      expect(points.length, 2);
      expect(points.first.lat, closeTo(52.52, 1e-9));
      expect(points.first.lon, closeTo(13.40, 1e-9));
      expect(points.first.ele, 41.0);
    });

    test('throws for ZIP without KML', () {
      // minimal ZIP-like container that the KMZ parser sniffs but cannot use:
      // a PK-headered file with no kml will fail during parse.
      final bogus = <int>[0x50, 0x4B, 0x03, 0x04, ...List.filled(64, 0)];
      expect(
        () => parser.parse(bogus),
        throwsA(isA<TrackParseException>()),
      );
    });

    test('plain (unzipped) KML from OpenTracks parses via the importer', () {
      const kml = '''
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
          <Document><name>Evening ride</name>
            <Placemark><name>Evening ride</name>
              <gx:Track>
                <when>2024-05-01T19:00:00Z</when>
                <gx:coord>13.40 52.52 40</gx:coord>
                <when>2024-05-01T19:00:05Z</when>
                <gx:coord>13.41 52.53 41</gx:coord>
              </gx:Track>
            </Placemark>
          </Document>
        </kml>
      ''';
      expect(kmlParser.accepts(kml.codeUnits), isTrue);
      final data = TrackImporter().import(kml.codeUnits, filename: 'evening.kml');
      expect(data.format, 'KML');
      expect(data.name, 'Evening ride');
      expect(data.points.length, 2);
      expect(data.points.first.lon, closeTo(13.40, 1e-9));
      expect(data.points.first.lat, closeTo(52.52, 1e-9));
    });
  });
}
