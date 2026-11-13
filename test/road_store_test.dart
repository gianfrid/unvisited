import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/road/road_format.dart';
import 'package:unvisited/road/road_store.dart';

import 'helpers.dart';

void main() {
  group('polyline5 codec', () {
    test('round-trips exact coordinates', () {
      const points = [
        (52.52000, 13.40500),
        (52.52100, 13.40600),
        (52.51950, 13.40450),
      ];
      final decoded = decodePolyline5(encodePolyline5(points));
      expect(decoded.length, points.length);
      for (var i = 0; i < points.length; i++) {
        expect(decoded[i].$1, closeTo(points[i].$1, 1e-5));
        expect(decoded[i].$2, closeTo(points[i].$2, 1e-5));
      }
    });

    test('matches the reference example from the polyline spec', () {
      // The Google documentation's worked example: (38.5, -120.2),
      // (40.7, -120.95), (43.252, -126.453) → the canonical string.
      final encoded = encodePolyline5([
        (38.5, -120.2),
        (40.7, -120.95),
        (43.252, -126.453),
      ]);
      expect(encoded, '_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      final decoded = decodePolyline5(encoded);
      // 1e-5 deg is the format's precision; float rounding can land a hair
      // past it, so compare at 2e-5 (~2 m — still finer than the fog grid).
      expect(decoded.first.$1, closeTo(38.5, 2e-5));
      expect(decoded.first.$2, closeTo(-120.2, 2e-5));
      expect(decoded.last.$1, closeTo(43.252, 2e-5));
      expect(decoded.last.$2, closeTo(-126.453, 2e-5));
    });

    test('handles negative deltas (south/west movement)', () {
      const points = [(52.52, 13.41), (52.51, 13.40)];
      final decoded = decodePolyline5(encodePolyline5(points));
      expect(decoded.last.$1, closeTo(52.51, 2e-5));
      expect(decoded.last.$2, closeTo(13.40, 2e-5));
    });

    test('rejects truncated input', () {
      expect(() => decodePolyline5('!!!'),
          throwsA(isA<RoadFormatException>()));
    });
  });

  group('bucket keys', () {
    test('a tile key is stable and street-scale', () {
      final key = roadBucketKeyFor(52.5200, 13.4050);
      expect(key, roadBucketKeyFor(52.5201, 13.4051));
      // A different city is in a different tile.
      expect(key, isNot(roadBucketKeyFor(48.8584, 2.2945)));
    });
  });

  group('RoadStore', () {
    RoadStore openFixture() =>
        RoadStore.parse(fixture('test_roads.unvisited-roads'));

    test('opens the synthetic fixture and exposes the ways', () {
      final store = openFixture();
      expect(store.wayCount, 3);
      expect(store.wayById('1001'), isNotNull);
      expect(store.wayById('1001')!.name, 'Main Street');
      expect(store.wayById('1001')!.highwayClass, 'residential');
      expect(store.wayById('9999'), isNull);
    });

    test('decodes geometry exactly', () {
      final way = openFixture().wayById('1001')!;
      final pts = way.points;
      expect(pts.length, 2);
      expect(pts.first, const LatLng(52.5200, 13.4050));
      expect(pts.last, const LatLng(52.5200, 13.4100));
    });

    test('buckets contain the ways crossing the tile', () {
      final store = openFixture();
      // All three fixture streets sit inside one z12 tile around Berlin.
      final bucket = store.bucketAt(52.5200, 13.4070);
      expect(bucket.map((w) => w.id), containsAll(['1001', '1002', '1003']));
      // An unrelated position's bucket is empty.
      expect(store.bucketAt(48.8584, 2.2945), isEmpty);
    });

    test('bucketKeysNear covers the tile edges', () {
      final store = openFixture();
      final keys = store.bucketKeysNear(52.5200, 13.4050);
      expect(keys.length, 9);
      expect(keys, contains(roadBucketKeyFor(52.5200, 13.4050)));
      // Querying all near keys finds the ways even from a tile-edge point.
      final found = [
        for (final key in keys) ...store.bucketByKey(key),
      ];
      expect(found.map((w) => w.id), containsAll(['1001', '1002', '1003']));
    });

    test('decodedPoints caches and stays consistent', () {
      final store = openFixture();
      final way = store.wayById('1002')!;
      final first = store.decodedPoints(way);
      final second = store.decodedPoints(way);
      expect(identical(first, second), isTrue,
          reason: 'repeat access must hit the cache');
      expect(second.first, const LatLng(52.5180, 13.4075));
    });

    test('rejects a wrong magic', () {
      final bytes = <int>[...utf8.encode('NOTAROADS'), 1, 0, 0, 0, 123];
      expect(() => RoadStore.parse(bytes),
          throwsA(isA<RoadFormatException>()));
    });

    test('rejects an unknown version', () {
      final bytes = <int>[...roadMagic, 99, 0, 0, 0, 123];
      expect(() => RoadStore.parse(bytes),
          throwsA(isA<RoadFormatException>()));
    });

    test('rejects a truncated payload', () {
      final bytes = <int>[...roadMagic, 1, 0xFF, 0, 0, 0];
      expect(() => RoadStore.parse(bytes),
          throwsA(isA<RoadFormatException>()));
    });

    test('rejects corrupt JSON', () {
      final payload = utf8.encode('{not json');
      final bytes = <int>[
        ...roadMagic,
        1,
        payload.length & 0xFF,
        (payload.length >> 8) & 0xFF,
        (payload.length >> 16) & 0xFF,
        (payload.length >> 24) & 0xFF,
        ...payload,
      ];
      expect(() => RoadStore.parse(bytes),
          throwsA(isA<RoadFormatException>()));
    });

    test('rejects a bucket referencing an unknown way', () {
      final payload = utf8.encode(
          '{"ways":[{"id":"1","pts":"_p~iF~ps|U"}],"buckets":{"0_0":[7]}}');
      final bytes = <int>[
        ...roadMagic,
        1,
        payload.length & 0xFF,
        (payload.length >> 8) & 0xFF,
        (payload.length >> 16) & 0xFF,
        (payload.length >> 24) & 0xFF,
        ...payload,
      ];
      expect(() => RoadStore.parse(bytes),
          throwsA(isA<RoadFormatException>()));
    });
  });
}
