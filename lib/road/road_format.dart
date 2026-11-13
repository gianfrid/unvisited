/// The offline road-data format: a binary container with a small JSON
/// directory and one JSON payload per spatial bucket.
///
/// Nothing road-related is fetched at runtime (SPEC): a desktop build CLI
/// (`tool/build_roads.dart`) preprocesses an osmium-filtered Geofabrik
/// extract into one file the user side-loads. The reader is pure Dart,
/// unit-testable, and a future Rust core can reimplement it from this
/// comment alone.
///
/// LAYOUT (version 2)
/// ```
/// "UNVROADS"           8 bytes, magic
/// uint8                format version (2)
/// uint32 LE            directory length N
/// N bytes              directory JSON: {"<x>_<y>": [offset, length], ...}
/// payload blobs        one JSON object per bucket, at its directory offset
/// ```
///
/// A bucket payload is `{"ways": [{"id", "class", "name", "pts"}, ...]}`,
/// where `pts` is the way's geometry as a polyline5 string (Google/Mapbox
/// algorithm at 5 decimal digits, ~1.1 m at the equator — finer than
/// consumer GPS and than the fog-cell grid; see
/// https://developers.google.com/maps/documentation/utilities/
/// polylinealgorithm).
///
/// The directory is the only thing read at open: a region-sized file (hundreds
/// of MB, millions of ways) opens in milliseconds and only the buckets a track
/// actually touches are ever parsed — the "bucket-loaded, bounded memory"
/// promise. A way spanning several buckets is duplicated into each (OSM ways
/// are short relative to a z12 tile, so the overhead is small).
///
/// Way ids are OSM way ids, stable across edits, so unlock state recorded
/// against them survives a re-extract.
library;

import 'dart:convert';
import 'dart:math' as math;

/// Magic bytes every road file starts with.
final List<int> roadMagic = utf8.encode('UNVROADS');

/// Format version; readers reject files whose version byte differs.
const int roadFormatVersion = 2;

class RoadFormatException implements Exception {
  RoadFormatException(this.message);

  final String message;

  @override
  String toString() => 'RoadFormatException: $message';
}

/// Encodes [points] (lat, lon pairs) as a polyline5 string.
String encodePolyline5(Iterable<(double, double)> points) {
  var prevLat = 0;
  var prevLon = 0;
  final out = StringBuffer();
  for (final (lat, lon) in points) {
    final ilat = (lat * 1e5).round();
    final ilon = (lon * 1e5).round();
    _writeVarint(ilat - prevLat, out);
    _writeVarint(ilon - prevLon, out);
    prevLat = ilat;
    prevLon = ilon;
  }
  return out.toString();
}

/// Decodes a polyline5 string into (lat, lon) pairs.
List<(double, double)> decodePolyline5(String encoded) {
  final result = <(double, double)>[];
  var index = 0;
  var lat = 0;
  var lon = 0;
  while (index < encoded.length) {
    lat += _readVarintSigned(encoded, index, (next) => index = next);
    lon += _readVarintSigned(encoded, index, (next) => index = next);
    result.add((lat / 1e5, lon / 1e5));
  }
  return result;
}

/// Zigzag-encoded unsigned varint, chars 63..126 per the polyline spec.
void _writeVarint(int value, StringBuffer out) {
  var v = value < 0 ? ((~value) << 1) | 1 : value << 1;
  while (v >= 0x20) {
    out.writeCharCode(((0x20 | (v & 0x1f)) + 63));
    v >>= 5;
  }
  out.writeCharCode(v + 63);
}

/// Reads one zigzag varint starting at [index]; reports the next index
/// through [next] so the caller drives two reads per point.
int _readVarintSigned(String s, int index, void Function(int) next) {
  var result = 0;
  var shift = 0;
  while (true) {
    if (index >= s.length) {
      throw RoadFormatException('truncated polyline');
    }
    final c = s.codeUnitAt(index++) - 63;
    if (c < 0) throw RoadFormatException('bad polyline char');
    result |= (c & 0x1f) << shift;
    if (c < 0x20) break;
    shift += 5;
  }
  next(index);
  // Zigzag decode: negative n encodes as (~n)<<1|1, so an odd value must
  // come back as ~(v>>1) — -(v>>1) alone loses 1 (−12020000 came back as
  // −12019999).
  return result.isOdd ? ~(result >> 1) : result >> 1;
}

/// The z12 tile key ("x_y") a lat/lon falls into — the spatial bucket unit.
String roadBucketKeyFor(double lat, double lon, {int zoom = 12}) {
  final n = math.pow(2, zoom).toDouble();
  final x = ((lon + 180) / 360 * n).floor();
  final latRad = lat * math.pi / 180;
  final y = ((1 -
          math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
      2 *
      n)
      .floor();
  return '${x}_$y';
}

/// The z12 tile key of the tile adjacent to (lat, lon) by [dx], [dy] tiles.
String roadBucketKeyOffset(double lat, double lon, int dx, int dy) {
  final key = roadBucketKeyFor(lat, lon);
  final parts = key.split('_');
  final x = int.parse(parts[0]) + dx;
  final y = int.parse(parts[1]) + dy;
  return '${x}_$y';
}

/// Serializes the container: a directory plus one payload blob per bucket.
///
/// [buckets] maps bucket key → the ways whose geometry belongs in it (a way
/// spanning buckets appears in each). Blobs are written in key order, so
/// output is deterministic for a given input.
List<int> encodeRoadFile(Map<String, List<Map<String, dynamic>>> buckets) {
  final keys = buckets.keys.toList()..sort();
  final directory = <String, List<int>>{};
  final blobs = <List<int>>[];
  var offset = 0;
  for (final key in keys) {
    final payload = utf8.encode(jsonEncode({'ways': buckets[key]}));
    // Offsets are relative to the first blob (the reader adds the header
    // length it just parsed).
    directory[key] = [offset, payload.length];
    blobs.add(payload);
    offset += payload.length;
  }
  final directoryBytes = utf8.encode(jsonEncode(directory));
  final header = <int>[
    ...roadMagic,
    roadFormatVersion,
    directoryBytes.length & 0xFF,
    (directoryBytes.length >> 8) & 0xFF,
    (directoryBytes.length >> 16) & 0xFF,
    (directoryBytes.length >> 24) & 0xFF,
    ...directoryBytes,
  ];
  // Blob offsets are relative to the end of the header; the reader computes
  // the base from the header length it just read.
  return [...header, for (final blob in blobs) ...blob];
}
