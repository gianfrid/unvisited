import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/geo.dart';

void main() {
  group('haversineMeters', () {
    test('identical points measure zero', () {
      expect(haversineMeters(45.0, 9.0, 45.0, 9.0), 0);
    });

    test('one degree of latitude is about 111.19 km', () {
      final d = haversineMeters(45.0, 9.0, 45.001, 9.0);
      expect(d, closeTo(111.19, 0.5));
    });

    test('one degree of longitude at the equator is about 111.19 km', () {
      final d = haversineMeters(0.0, 0.0, 0.0, 0.001);
      expect(d, closeTo(111.19, 0.5));
    });

    test('longitude legs shrink by the cosine of the latitude', () {
      final equator = haversineMeters(0.0, 0.0, 0.0, 1.0);
      final at60 = haversineMeters(60.0, 0.0, 60.0, 1.0);
      expect(at60, closeTo(equator / 2, 1));
    });
  });

  group('initialBearingDeg', () {
    const lat = 45.0;
    const lon = 9.0;
    const eps = 0.001;

    test('due north', () {
      expect(initialBearingDeg(lat, lon, lat + eps, lon), closeTo(0, 0.1));
    });

    test('due east', () {
      expect(initialBearingDeg(lat, lon, lat, lon + eps), closeTo(90, 0.1));
    });

    test('due south', () {
      expect(initialBearingDeg(lat, lon, lat - eps, lon), closeTo(180, 0.1));
    });

    test('due west', () {
      expect(initialBearingDeg(lat, lon, lat, lon - eps), closeTo(270, 0.1));
    });

    test('result always wraps into [0, 360)', () {
      final b = initialBearingDeg(lat, lon, lat, lon - eps);
      expect(b >= 0 && b < 360, isTrue);
    });
  });
}
