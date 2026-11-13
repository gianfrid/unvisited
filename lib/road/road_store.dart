import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';

import 'road_format.dart';

/// One OSM way (road segment) in the road store: identity, classification,
/// name and lazily decoded geometry. The container holds polyline5 strings;
/// decoding happens on first [points] access.
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
/// Opening parses only the bucket directory; bucket payloads are parsed on
/// demand and held in a small LRU, so a region-sized file costs memory
/// proportional to the area being visited, not to the file. Pure Dart, no
/// Flutter — a future Rust core replaces this class behind the same
/// interface.
class RoadStore {
  RoadStore._(this._bytes, this._file, this._blobBase,
      Map<String, List<int>> directory)
      : _directory = directory;

  /// In-memory source (tests, small fixtures). Null when reading from disk.
  final List<int>? _bytes;

  /// Disk source: bucket slices are read on demand, so a region-sized file
  /// costs memory proportional to the parsed buckets, not to the file.
  final RandomAccessFile? _file;

  /// Offset of the first bucket blob (end of the header).
  final int _blobBase;

  /// Bucket key → (offset relative to [_blobBase], length).
  final Map<String, List<int>> _directory;

  /// Parsed-bucket LRU: insertion-ordered, evicting the oldest beyond the
  /// limit. A bucket holds every way in one ~10 km z12 tile, so a handful
  /// covers a walk's whole neighborhood.
  static const _bucketCacheLimit = 8;
  final Map<String, List<RoadWay>> _bucketCache = {};

  /// Number of spatial buckets (z12 tiles) in the file.
  int get bucketCount => _directory.length;

  /// How many bucket payloads have been parsed so far. Exposed so tests can
  /// assert the lazy-loading contract (a walk parses only the buckets it
  /// touches, never the whole region file) without timing assertions.
  int get parsedBucketCount => _parsedBucketCount;
  int _parsedBucketCount = 0;

  /// All bucket keys present in the file.
  Iterable<String> get bucketKeys => _directory.keys;

  /// All ways whose geometry belongs to the z12 tile containing (lat, lon).
  /// Neighboring tiles are *not* included — callers matching points near a
  /// tile edge query the neighbors too (see [bucketKeysNear]).
  List<RoadWay> bucketAt(double lat, double lon) =>
      bucketByKey(roadBucketKeyFor(lat, lon));

  /// The bucket key for a position plus its 8 neighbors: the set a matcher
  /// must query to catch ways just across a tile edge.
  List<String> bucketKeysNear(double lat, double lon) => [
        for (var dx = -1; dx <= 1; dx++)
          for (var dy = -1; dy <= 1; dy++)
            roadBucketKeyOffset(lat, lon, dx, dy),
      ];

  /// Ways in the named bucket (empty when the bucket does not exist).
  List<RoadWay> bucketByKey(String key) {
    final cached = _bucketCache.remove(key);
    if (cached != null) {
      _bucketCache[key] = cached; // re-insert as most recent
      return cached;
    }
    final entry = _directory[key];
    if (entry == null) return const [];
    final ways = _parseBucket(key, entry[0], entry[1]);
    _parsedBucketCount++;
    while (_bucketCache.length >= _bucketCacheLimit) {
      _bucketCache.remove(_bucketCache.keys.first);
    }
    _bucketCache[key] = ways;
    return ways;
  }

  List<RoadWay> _parseBucket(String key, int offset, int length) {
    final start = _blobBase + offset;
    final List<int> slice;
    final bytes = _bytes;
    if (bytes != null) {
      final end = start + length;
      if (start < 0 || end > bytes.length) {
        throw RoadFormatException(
            'bucket $key runs past the end of the file');
      }
      slice = bytes.sublist(start, end);
    } else {
      final file = _file!;
      file.setPositionSync(start);
      slice = file.readSync(length);
      if (slice.length != length) {
        throw RoadFormatException(
            'bucket $key runs past the end of the file');
      }
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(slice));
    } on FormatException catch (e) {
      throw RoadFormatException('corrupt bucket $key: $e');
    }
    if (decoded is! Map || decoded['ways'] is! List) {
      throw RoadFormatException('bucket $key missing ways');
    }
    final ways = <RoadWay>[];
    for (final raw in decoded['ways'] as List) {
      if (raw is! Map) throw RoadFormatException('malformed way in $key');
      final id = raw['id'];
      final pts = raw['pts'];
      if (id is! String || pts is! String) {
        throw RoadFormatException('way in $key missing id or geometry');
      }
      ways.add(RoadWay(
          id, raw['class'] as String? ?? '', raw['name'] as String? ?? '', pts));
    }
    return ways;
  }

  /// Opens and validates a road file, reading bucket payloads from disk on
  /// demand. Throws [RoadFormatException] on a wrong magic, unknown version
  /// or corrupt directory — never silently returns an empty store (a broken
  /// file must be visible, not ignored). Close it with [close] when done.
  factory RoadStore.open(String path) {
    final file = File(path).openSync();
    try {
      // Read the fixed header prefix, then the directory it announces; the
      // rest of the file is never touched until a bucket is requested.
      file.setPositionSync(0);
      final prefix = file.readSync(roadMagic.length + 5);
      if (prefix.length < roadMagic.length + 5) {
        throw RoadFormatException('file too short (${prefix.length} bytes)');
      }
      final directoryLength = prefix[roadMagic.length + 1] |
          (prefix[roadMagic.length + 2] << 8) |
          (prefix[roadMagic.length + 3] << 16) |
          (prefix[roadMagic.length + 4] << 24);
      final directoryBytes = file.readSync(directoryLength);
      return RoadStore._(
          null,
          file,
          roadMagic.length + 5 + directoryLength,
          _parseHeader(prefix, directoryBytes, directoryLength));
    } on RoadFormatException {
      file.closeSync();
      rethrow;
    } on FileSystemException {
      file.closeSync();
      rethrow;
    }
  }

  /// Parses road-file bytes (see [open]).
  factory RoadStore.parse(List<int> bytes) {
    if (bytes.length < roadMagic.length + 5) {
      throw RoadFormatException('file too short (${bytes.length} bytes)');
    }
    final lengthAt = roadMagic.length + 1;
    final directoryLength = bytes[lengthAt] |
        (bytes[lengthAt + 1] << 8) |
        (bytes[lengthAt + 2] << 16) |
        (bytes[lengthAt + 3] << 24);
    final blobBase = lengthAt + 4 + directoryLength;
    if (directoryLength < 0 || blobBase > bytes.length) {
      throw RoadFormatException('truncated file (directory cut off)');
    }
    final directory = _parseHeader(
        bytes.sublist(0, lengthAt + 4),
        bytes.sublist(lengthAt + 4, blobBase),
        directoryLength,
        fileLength: bytes.length,
        blobBase: blobBase);
    return RoadStore._(bytes, null, blobBase, directory);
  }

  /// Validates the magic/version and parses the directory JSON. [prefix] is
  /// at least magic+5 bytes; [directoryBytes] is the directory payload.
  static Map<String, List<int>> _parseHeader(
      List<int> prefix, List<int> directoryBytes, int directoryLength,
      {int? fileLength, int? blobBase}) {
    for (var i = 0; i < roadMagic.length; i++) {
      if (prefix[i] != roadMagic[i]) {
        throw RoadFormatException('not a road file (bad magic)');
      }
    }
    final version = prefix[roadMagic.length];
    if (version != roadFormatVersion) {
      throw RoadFormatException('unsupported road format version $version '
          '(expected $roadFormatVersion)');
    }
    if (directoryBytes.length != directoryLength) {
      throw RoadFormatException('truncated file (directory cut off)');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(directoryBytes));
    } on FormatException catch (e) {
      throw RoadFormatException('corrupt directory: $e');
    }
    if (decoded is! Map) throw RoadFormatException('directory is not an object');
    final directory = <String, List<int>>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (entry.key is! String || value is! List || value.length != 2) {
        throw RoadFormatException('malformed directory entry');
      }
      final offset = value[0];
      final length = value[1];
      if (offset is! int || length is! int || offset < 0 || length < 0) {
        throw RoadFormatException('malformed directory offsets');
      }
      if (fileLength != null &&
          blobBase != null &&
          blobBase + offset + length > fileLength) {
        throw RoadFormatException('directory points past the end of file');
      }
      directory[entry.key as String] = [offset, length];
    }
    return directory;
  }

  /// Releases the file handle (no-op for an in-memory store).
  void close() {
    _file?.closeSync();
  }
}
