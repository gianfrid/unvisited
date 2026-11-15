import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/tile_source.dart';

/// Integration check against the live tile servers configured in
/// [tileUrlTemplate].
///
/// These tests hit the network on purpose: they verify that the OSM raster
/// server is reachable, serves tiles for the User-Agent configured in
/// [tileUserAgent], and is not rate-limiting us - all requirements from the
/// OSM tile usage policy (https://operations.osmfoundation.org/policies/tiles/).
/// If these fail with connection errors or 403/429 responses, the tile source
/// must be revisited (identifying User-Agent, volume, or another provider).
///
/// Opt-in, so the default `flutter test` stays offline and independent of
/// OSM tile-server availability. Run them with:
///
///   flutter test --dart-define=TILE_SERVER_TESTS=true
// ignore_for_file: avoid_redundant_argument_values
const _networkSkipped = bool.fromEnvironment('TILE_SERVER_TESTS')
    ? false
    : 'hits the live OSM tile servers — run with '
          '`flutter test --dart-define=TILE_SERVER_TESTS=true`';

void main() {
  // Berlin city center; tiles around the map's start position.
  const z = 13, x = 4386, y = 2686;

  Future<(HttpClientResponse, Uint8List)> fetch(int tx, int ty) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(tileUrl(z, tx, ty)))
        ..headers.set(HttpHeaders.userAgentHeader, tileUserAgent);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      return (response, bytes.toBytes());
    } finally {
      client.close();
    }
  }

  void expectPngTile(HttpClientResponse response, Uint8List bytes) {
    expect(
      response.statusCode,
      HttpStatus.ok,
      reason:
          'Tile server rejected the request on '
          '${response.headers.value(HttpHeaders.userAgentHeader) ?? '...'}'
          '${response.statusCode == 403 || response.statusCode == 429 ? ' - blocked or rate-limited; check the OSM tile usage policy' : ''}',
    );
    expect(
      bytes.length,
      greaterThan(1000),
      reason: 'expected a real tile image, got ${bytes.length} bytes',
    );
    expect(
      bytes.sublist(0, 4),
      const [0x89, 0x50, 0x4E, 0x47], // PNG magic
      reason: 'tile is not a PNG image',
    );
  }

  group('live tile servers', () {
    test(
      'configured tile server serves Berlin tiles for our User-Agent',
      () async {
        final (response, bytes) = await fetch(x, y);
        expectPngTile(response, bytes);
      },
    );

    test('a small burst of tiles downloads without rate limiting', () async {
      // Importing a folder grabs a screen-full of tiles at once; a handful
      // of parallel requests must not trip rate limiting.
      final results = await Future.wait([
        fetch(x, y),
        fetch(x + 1, y),
        fetch(x - 1, y),
        fetch(x, y + 1),
        fetch(x, y - 1),
        fetch(x + 1, y + 1),
      ]);
      for (final (response, bytes) in results) {
        expectPngTile(response, bytes);
      }
    });

    test('tile responses carry the metadata the offline cache needs', () async {
      // The built-in tile cache ages stored tiles from HTTP caching headers;
      // without any of these the offline cache cannot work properly.
      final (response, _) = await fetch(x, y);
      final hasCacheHeaders = [
        'etag',
        'last-modified',
        'cache-control',
        'expires',
      ].any((h) => response.headers.value(h) != null);
      expect(
        hasCacheHeaders,
        isTrue,
        reason:
            'tile response has neither ETag, Last-Modified, Cache-Control '
            'nor Expires; the offline cache could not invalidate tiles',
      );
    });

    Future<(HttpClientResponse, Uint8List)> fetchCycle(int tx, int ty) async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.getUrl(Uri.parse(cycleTileUrl(z, tx, ty)))
          ..headers.set(HttpHeaders.userAgentHeader, tileUserAgent);
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          bytes.add(chunk);
        }
        return (response, bytes.toBytes());
      } finally {
        client.close();
      }
    }

    test('the CyclOSM cycle layer serves tiles for our User-Agent', () async {
      // The optional cycle tile style comes from OpenStreetMap France's
      // CyclOSM servers: same identifying User-Agent, same politeness rules.
      final (response, bytes) = await fetchCycle(x, y);
      expectPngTile(response, bytes);
    });
  }, skip: _networkSkipped);
}
