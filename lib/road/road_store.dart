import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';

import 'road_format.dart';

/// One OSM way (road segment) in the road store: identity, classification,
/// name and lazily decoded geometry. The container holds polyline5 strings;
/// decoding happens on first [points] access, so opening a region file costs
/// one JSON parse, not one geometry decode per street.
class RoadWay {
  RoadWay(this._id, this._highwayClass, this._name, this._encoded);

  final String _id;
  final String _highwayClass;
  final String _name;
  final String _encoded;
  List<LatLng>? _decoded;

  /// OSM way id (stable across OSM edits; unlock state keys on it).
  String get id => _id;

  /// The `highway=*` value (`residential`, `footway`, …).
  String get highwayClass => _highwayClass;

  String get name => _name;

  /// The way's geometry, decoded on first access.
  List<LatLng> get points =>
      _decoded ??= [
        for (final (lat, lon) in decodePolyline5(_encoded)) LatLng(lat, lon),
      ];
}

/// The offline road-data store: reads one side-loaded road file (see
/// `road_format.dart`) and answers "which roads are near this position".
///
/// Decoded geometries are capped by a small LRU so walking a long track
/// across many buckets cannot grow memory without bound. Pure Dart, no
/// Flutter — a future Rust core replaces this class behind the same
/// interface.
class RoadStore {
  RoadStore._(List<RoadWay> ways, Map<String, List<int>> buckets)
      : _ways = ways,
        _buckets = buckets,
        _wayById = {for (final w in ways) w.id: w};

  final List<RoadWay> _ways;
  final Map<String, List<int>> _buckets;
  final Map<String, RoadWay> _wayById;

  /// Decoded-geometry LRU: LinkedHashMap keyed by way id, insertion-ordered;
  /// on overflow the least recently *used* entry is evicted and its geometry
  /// dropped (re-decodable from the polyline string).
  static const _decodedCacheLimit = 64;
  final Map<String, List<LatLng>> _decodedCache = {};

  /// Number of ways in the file.
  int get wayCount => _ways.length;

  /// The way with the given OSM id, or null.
  RoadWay? wayById(String id) => _wayById[id];

  /// All ways whose geometry intersects the z12 tile containing (lat, lon).
  /// Neighboring tiles are *not* included — callers matching points near a
  /// tile edge query the neighbors too (see [bucketKeysNear]).
  List<RoadWay> bucketAt(double lat, double lon) =>
      bucketByKey(roadBucketKeyFor(lat, lon));

  /// The bucket key for a position plus its 8 neighbors: the set a matcher
  /// must query to catch ways just across a tile edge.
  List<String> bucketKeysNear(double lat, double lon) {
    final key = roadBucketKeyFor(lat, lon);
    final parts = key.split('_');
    final x = int.parse(parts[0]);
    final y = int.parse(parts[1]);
    return [
      for (var dx = -1; dx <= 1; dx++)
        for (var dy = -1; dy <= 1; dy++) '${x + dx}_${y + dy}',
    ];
  }

  /// Ways in the named bucket (empty when the bucket does not exist).
  List<RoadWay> bucketByKey(String key) => [
        for (final index in _buckets[key] ?? const <int>[]) _ways[index],
      ];

  /// Decodes a way's geometry through the LRU cache.
  List<LatLng> decodedPoints(RoadWay way) {
    final cached = _decodedCache.remove(way.id);
    if (cached != null) {
      _decodedCache[way.id] = cached; // re-insert as most recent
      return cached;
    }
    final points = way.points;
    while (_decodedCache.length >= _decodedCacheLimit) {
      _decodedCache.remove(_decodedCache.keys.first);
    }
    _decodedCache[way.id] = points;
    return points;
  }

  /// Opens and validates a road file. Throws [RoadFormatException] on a
  /// wrong magic, unknown version or corrupt payload — never silently
  /// returns an empty store (a broken file must be visible, not ignored).
  factory RoadStore.open(String path) {
    final bytes = File(path).readAsBytesSync();
    return RoadStore.parse(bytes);
  }

  /// Parses road-file bytes (see [open]).
  factory RoadStore.parse(List<int> bytes) {
    if (bytes.length < roadMagic.length + 2) {
      throw RoadFormatException('file too short (${bytes.length} bytes)');
    }
    for (var i = 0; i < roadMagic.length; i++) {
      if (bytes[i] != roadMagic[i]) {
        throw RoadFormatException('not a road file (bad magic)');
      }
    }
    final version = bytes[roadMagic.length];
    if (version != roadFormatVersion) {
      throw RoadFormatException(
          'unsupported road format version $version '
          '(expected $roadFormatVersion)');
    }
    final lengthBytes =
        bytes.sublist(roadMagic.length + 1, roadMagic.length + 5);
    final jsonLength = lengthBytes[0] |
        (lengthBytes[1] << 8) |
        (lengthBytes[2] << 16) |
        (lengthBytes[3] << 24);
    if (jsonLength < 0 ||
        roadMagic.length + 5 + jsonLength > bytes.length) {
      throw RoadFormatException('truncated file (payload cut off)');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(
          bytes.sublist(roadMagic.length + 5, roadMagic.length + 5 +
              jsonLength)));
    } on FormatException catch (e) {
      throw RoadFormatException('corrupt payload: $e');
    }
    if (decoded is! Map) throw RoadFormatException('payload is not an object');
    final waysJson = decoded['ways'];
    final bucketsJson = decoded['buckets'];
    if (waysJson is! List || bucketsJson is! Map) {
      throw RoadFormatException('payload missing ways or buckets');
    }
    final ways = <RoadWay>[];
    for (final raw in waysJson) {
      if (raw is! Map) throw RoadFormatException('malformed way entry');
      final id = raw['id'];
      final pts = raw['pts'];
      if (id is! String || pts is! String) {
        throw RoadFormatException('way missing id or geometry');
      }
      try {
        decodePolyline5(pts);
      } on RoadFormatException {
        rethrow;
      }
      ways.add(RoadWay(id, raw['class'] as String? ?? '',
          raw['name'] as String? ?? '', pts));
    }
    final buckets = <String, List<int>>{};
    for (final entry in bucketsJson.entries) {
      final list = (entry.value as List).cast<int>();
      for (final index in list) {
        if (index < 0 || index >= ways.length) {
          throw RoadFormatException('bucket references unknown way $index');
        }
      }
      buckets[entry.key as String] = list;
    }
    return RoadStore._(ways, buckets);
  }
}
