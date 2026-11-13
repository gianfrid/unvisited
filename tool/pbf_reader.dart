// ignore_for_file: avoid_print
// Hand-written streaming reader for the OSM protobuf format (.osm.pbf),
// used only by the road-data build CLI (a dev tool — nothing here ships in
// the APK or introduces a package dependency).
//
// Why hand-written: the research report's candidate `dart_osmpbf` pins
// `archive ^3.6.1`, which conflicts with the app's `archive ^4.6.0` (pub
// resolution fails outright), and it loads the whole file into memory —
// ruled out at region scale in the report. The read path is small enough to
// hand-roll: the format (fileformat.proto + osmformat.proto, documented at
// https://wiki.openstreetmap.org/wiki/PBF_Format) is a sequence of frames
//
//   uint32 BE   BlobHeader length N
//   N bytes     BlobHeader protobuf (type "OSMHeader" | "OSMData", datasize)
//   datasize    Blob protobuf (raw payload or decompressed zlib_data)
//
// where each OSMData payload is a PrimitiveBlock: a string table plus
// primitive groups holding nodes (plain messages, or delta-coded "dense"
// rows) and ways (delta-coded node refs, tags as string-table indices).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The result of [extractHighwayWays].
class PbfExtraction {
  PbfExtraction({
    required this.ways,
    required this.totalWays,
    required this.highwayWays,
    required this.shortWays,
    required this.missingNodeWays,
    required this.truncatedBlobs,
  });

  /// The extracted ways, in the Map shape `buildRoadFile` consumes:
  /// `{id, class, name, points}` with `points` a `[lat, lon]` list in
  /// degrees.
  final List<Map> ways;

  /// Every way found in the file (the filter drops the rest).
  final int totalWays;

  /// Ways carrying a `highway` tag (all classes, per the decided scope).
  final int highwayWays;

  /// Highway ways dropped for having fewer than two resolvable nodes.
  final int shortWays;

  /// Highway ways dropped because a referenced node was not in the file.
  final int missingNodeWays;

  /// Truncated trailing frames skipped (a cut-off file is tolerated, like
  /// the app tolerates truncated track imports).
  final int truncatedBlobs;
}

/// Content sniff: a PBF file starts with the 4-byte big-endian length of
/// its first BlobHeader, whose `type` is "OSMHeader" — byte 0x0A (field 1,
/// length-delimited), length 0x09, then that string. So the marker sits at
/// offset 4 (writers serialize the required type field first); scan the
/// short prefix for it. Checks content, not the filename, like the app's
/// track import does.
bool looksLikeOsmPbf(List<int> head) {
  const type = 'OSMHeader';
  for (
    var start = 0;
    start + 2 + type.length <= head.length && start < 8;
    start++
  ) {
    if (head[start] != 0x0A) continue;
    if (head[start + 1] != type.length) continue;
    var match = true;
    for (var i = 0; i < type.length; i++) {
      if (head[start + 2 + i] != type.codeUnitAt(i)) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Extracts every way carrying a `highway` tag (all classes) from the OSM
/// PBF file at [path]. Two streaming passes keep memory bounded by the
/// highway-referenced nodes, not the file size: pass one collects highway
/// ways and their node ids, pass two resolves those ids to coordinates (so
/// the input may be a pre-filtered osmium extract or the full region file —
/// the filter below drops non-roads either way). Warnings go to
/// [onWarning] when given.
PbfExtraction extractHighwayWays(
  String path, {
  void Function(String)? onWarning,
}) {
  final file = File(path).openSync();
  try {
    // Pass 1: ways with a highway tag, plus the node ids their geometry
    // needs.
    final needed = <int>{};
    final selected = <({int id, String type, String name, List<int> refs})>[];
    var totalWays = 0;
    final truncated = _forEachBlob(file, (blob) {
      if (blob.type != 'OSMData') return;
      final block = _parsePrimitiveBlock(blob.payload);
      final highwayIdx = block.strings.indexOf('highway');
      if (highwayIdx < 0) return;
      for (final group in block.groups) {
        _forEachGroupField(
          group,
          field: 3,
          visit: (wayReader) {
            totalWays++;
            final way = _parseWay(wayReader);
            final wayId = way.id;
            String type = '';
            String name = '';
            for (var i = 0; i < way.keys.length && i < way.vals.length; i++) {
              if (way.keys[i] == highwayIdx) {
                type = block.strings.elementAtOrNull(way.vals[i]) ?? '';
              } else if (way.keys[i] == block.nameIdx) {
                name = block.strings.elementAtOrNull(way.vals[i]) ?? '';
              }
            }
            if (type.isEmpty) return; // not a road
            selected.add((id: wayId, type: type, name: name, refs: way.refs));
            needed.addAll(way.refs);
          },
        );
      }
    });
    if (truncated > 0) {
      onWarning?.call(
        'warning: $truncated truncated blob(s) at the end of '
        'the file were skipped',
      );
    }

    // Pass 2: coordinates for exactly the referenced nodes.
    final nodes = <int, (double, double)>{};
    _forEachBlob(file, (blob) {
      if (blob.type != 'OSMData') return;
      final block = _parsePrimitiveBlock(blob.payload);
      for (final group in block.groups) {
        // Plain Node messages and the dense form both occur (osmium writes
        // dense; hand-made files may not) — one field walk handles both.
        while (!group.done) {
          final (field, wire) = group.readTag();
          if (field == 1 && wire == 2) {
            final node = _parsePlainNode(group.message());
            if (needed.contains(node.id)) {
              nodes[node.id] = block.toDegrees(node.lat, node.lon);
            }
          } else if (field == 2 && wire == 2) {
            _collectDenseNodes(group.message(), block, needed, nodes);
          } else {
            group.skipField(wire);
          }
        }
      }
    });

    // Assemble geometry; drop ways whose nodes did not resolve.
    final ways = <Map>[];
    var shortWays = 0;
    var missingNodeWays = 0;
    var missingWarned = false;
    for (final way in selected) {
      final points = <List<double>>[];
      var resolved = true;
      for (final ref in way.refs) {
        final node = nodes[ref];
        if (node == null) {
          resolved = false;
          break;
        }
        points.add([node.$1, node.$2]);
      }
      if (!resolved) {
        missingNodeWays++;
        if (!missingWarned) {
          missingWarned = true;
          onWarning?.call(
            'warning: some ways reference nodes that are not '
            'in the file (was the input filtered in a way that dropped '
            'referenced nodes?); those ways are dropped',
          );
        }
        continue;
      }
      if (points.length < 2) {
        shortWays++;
        continue;
      }
      ways.add({
        'id': '${way.id}',
        'class': way.type,
        'name': way.name,
        'points': points,
      });
    }
    return PbfExtraction(
      ways: ways,
      totalWays: totalWays,
      highwayWays: selected.length,
      shortWays: shortWays,
      missingNodeWays: missingNodeWays,
      truncatedBlobs: truncated,
    );
  } finally {
    file.closeSync();
  }
}

// ---- top-level frames -------------------------------------------------

class _Blob {
  _Blob(this.type, this.payload);

  final String type;
  final Uint8List payload; // decompressed message bytes
}

/// Reads exactly [buf.length] bytes at the current position, or fewer at
/// end of file.
int _readExactly(RandomAccessFile file, Uint8List buf) =>
    file.readIntoSync(buf, 0, buf.length);

/// Walks the file's top-level frames, handing each decompressed blob to
/// [onBlob]. Returns the number of truncated trailing frames skipped: a
/// cut-off file is tolerated, matching how the app tolerates truncated
/// track imports.
int _forEachBlob(RandomAccessFile file, void Function(_Blob) onBlob) {
  final length = file.lengthSync();
  var pos = 0;
  var truncated = 0;
  final sizeBuf = Uint8List(4);
  while (pos + 4 <= length) {
    file.setPositionSync(pos);
    if (_readExactly(file, sizeBuf) != 4) {
      truncated++;
      break;
    }
    final headerLen =
        (sizeBuf[0] << 24) |
        (sizeBuf[1] << 16) |
        (sizeBuf[2] << 8) |
        sizeBuf[3];
    final frameEnd = pos + 4 + headerLen;
    if (headerLen == 0 || headerLen > 1 << 20 || frameEnd > length) {
      truncated++;
      break;
    }
    final headerBuf = Uint8List(headerLen);
    if (_readExactly(file, headerBuf) != headerLen) {
      truncated++;
      break;
    }
    final (type, datasize) = _parseBlobHeader(headerBuf);
    final bodyEnd = frameEnd + datasize;
    if (bodyEnd > length) {
      truncated++;
      break;
    }
    final bodyBuf = Uint8List(datasize);
    if (_readExactly(file, bodyBuf) != datasize) {
      truncated++;
      break;
    }
    pos = bodyEnd;
    onBlob(_Blob(type, _blobPayload(bodyBuf)));
  }
  return truncated;
}

/// Parses a BlobHeader: `type = 1` (string), `indexdata = 2` (skipped),
/// `datasize = 3` (varint).
(String, int) _parseBlobHeader(Uint8List bytes) {
  String type = '';
  var datasize = 0;
  final r = _ProtoReader(bytes);
  while (!r.done) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        type = utf8.decode(r.message().rest());
      case 3:
        datasize = r.readVarint();
      default:
        r.skipField(wire);
    }
  }
  if (type.isEmpty || datasize <= 0) {
    throw FormatException(
      'malformed PBF BlobHeader (type "$type", '
      'datasize $datasize)',
    );
  }
  return (type, datasize);
}

/// Resolves a Blob's compression: `raw = 1`, `raw_size = 2` (unused here),
/// `zlib_data = 3`. Other compressions (lzma, lz4, zstd) are rejected with
/// a clear message — osmium and Geofabrik write zlib.
Uint8List _blobPayload(Uint8List body) {
  _ProtoReader? raw;
  List<int>? compressed;
  final r = _ProtoReader(body);
  while (!r.done) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        raw = r.message();
      case 3:
        compressed = r.message().rest();
      default:
        r.skipField(wire);
    }
  }
  if (raw != null) return raw.rest();
  if (compressed != null) return zlibDecode(compressed);
  throw const FormatException(
    'unsupported PBF blob compression (need raw or zlib)',
  );
}

/// zlib-decodes a Blob's zlib_data payload (PBF zlib_data is a standard
/// zlib stream).
Uint8List zlibDecode(List<int> bytes) =>
    Uint8List.fromList(zlib.decoder.convert(bytes));

// ---- PrimitiveBlock (osmformat.proto) ----------------------------------

class _Block {
  _Block(
    this.strings,
    this.granularity,
    this.latOffset,
    this.lonOffset,
    this.groups,
    this.nameIdx,
  );

  final List<String> strings;
  final int granularity;
  final int latOffset;
  final int lonOffset;
  final List<_ProtoReader> groups;
  final int nameIdx;

  /// Node values are nanodegrees: `offset + granularity * value`.
  (double, double) toDegrees(int lat, int lon) => (
    (latOffset + granularity * lat) / 1e9,
    (lonOffset + granularity * lon) / 1e9,
  );
}

/// Parses a PrimitiveBlock's scalars and string table; the primitive groups
/// are kept as positioned sub-readers for the caller to walk.
_Block _parsePrimitiveBlock(Uint8List bytes) {
  final strings = <String>[];
  final groups = <_ProtoReader>[];
  var granularity = 100; // proto defaults
  var latOffset = 0;
  var lonOffset = 0;
  final r = _ProtoReader(bytes);
  while (!r.done) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1: // StringTable: repeated bytes s = 1
        final table = r.message();
        while (!table.done) {
          final (tField, tWire) = table.readTag();
          if (tField == 1 && tWire == 2) {
            strings.add(utf8.decode(table.message().rest()));
          } else {
            table.skipField(tWire);
          }
        }
      case 2:
        groups.add(r.message());
      case 17:
        granularity = r.readSint();
      case 19:
        latOffset = r.readVarint();
      case 20:
        lonOffset = r.readVarint();
      default:
        r.skipField(wire);
    }
  }
  return _Block(
    strings,
    granularity,
    latOffset,
    lonOffset,
    groups,
    strings.indexOf('name'),
  );
}

/// Walks the group's fields numbered [field], handing each (length-
/// delimited) one to [visit]; other fields are skipped.
void _forEachGroupField(
  _ProtoReader group, {
  required int field,
  required void Function(_ProtoReader) visit,
}) {
  while (!group.done) {
    final (f, wire) = group.readTag();
    if (f == field && wire == 2) {
      visit(group.message());
    } else {
      group.skipField(wire);
    }
  }
}

class _Way {
  _Way(this.id, this.keys, this.vals, this.refs);

  final int id;
  final List<int> keys;
  final List<int> vals;

  /// Delta-coded node refs, decoded back to absolute ids.
  final List<int> refs;
}

/// Parses a Way: `id = 1` (int64), keys/vals = 2/3 (packed uint32
/// string-table indices), refs = 8 (packed sint64, delta-coded).
_Way _parseWay(_ProtoReader r) {
  var id = 0;
  final keys = <int>[];
  final vals = <int>[];
  final refs = <int>[];
  while (!r.done) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        id = r.readVarint();
      case 2:
        r.readPackedUint32(keys);
      case 3:
        r.readPackedUint32(vals);
      case 8:
        var pos = 0;
        r.readPackedSint((v) {
          pos += v;
          refs.add(pos);
        });
      default:
        r.skipField(wire);
    }
  }
  return _Way(id, keys, vals, refs);
}

class _PlainNode {
  _PlainNode(this.id, this.lat, this.lon);

  final int id;
  final int lat;
  final int lon;
}

/// Parses a plain Node: `id = 1` (sint64), keys/vals = 2/3, info = 4,
/// `lat = 8`, `lon = 9` (sint64 nanodegrees relative to the block's
/// offset/granularity).
_PlainNode _parsePlainNode(_ProtoReader r) {
  var id = 0;
  var lat = 0;
  var lon = 0;
  while (!r.done) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        id = r.readSint();
      case 8:
        lat = r.readSint();
      case 9:
        lon = r.readSint();
      default:
        r.skipField(wire);
    }
  }
  return _PlainNode(id, lat, lon);
}

/// Parses a group's DenseNodes row set and records the needed ones.
/// `ids = 1`, `denseinfo = 5`, `lat = 8`, `lon = 9`, `keys_vals = 10` —
/// all delta-coded packed sint64 sequences (tags in the dense form come as
/// one interleaved keys_vals list, which the geometry-only reader skips).
void _collectDenseNodes(
  _ProtoReader r,
  _Block block,
  Set<int> needed,
  Map<int, (double, double)> nodes,
) {
  final ids = <int>[];
  final lats = <int>[];
  final lons = <int>[];
  while (!r.done) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        r.readPackedSint(ids.add);
      case 8:
        r.readPackedSint(lats.add);
      case 9:
        r.readPackedSint(lons.add);
      default:
        r.skipField(wire);
    }
  }
  if (ids.length != lats.length || ids.length != lons.length) {
    throw const FormatException('malformed DenseNodes (ragged columns)');
  }
  var id = 0;
  var lat = 0;
  var lon = 0;
  for (var i = 0; i < ids.length; i++) {
    id += ids[i];
    lat += lats[i];
    lon += lons[i];
    if (needed.contains(id)) {
      nodes[id] = block.toDegrees(lat, lon);
    }
  }
}

// ---- protobuf wire primitives ------------------------------------------

class _ProtoReader {
  _ProtoReader(this.bytes, [int start = 0, int? end])
    : _pos = start,
      _end = end ?? bytes.length;

  final Uint8List bytes;
  int _pos;
  final int _end;

  bool get done => _pos >= _end;

  /// A sub-reader over the next length-delimited field's content.
  _ProtoReader message() {
    final len = readVarint();
    if (_pos + len > _end) {
      throw const FormatException('truncated protobuf (length runs out)');
    }
    final sub = _ProtoReader(bytes, _pos, _pos + len);
    _pos += len;
    return sub;
  }

  /// Consumes and returns the remainder under this reader (a whole
  /// length-delimited value read as bytes).
  Uint8List rest() {
    final result = Uint8List.sublistView(bytes, _pos, _end);
    _pos = _end;
    return result;
  }

  /// Reads a field tag: (field number, wire type).
  (int, int) readTag() {
    final tag = readVarint();
    final field = tag >> 3;
    if (field == 0) throw const FormatException('invalid protobuf field 0');
    return (field, tag & 7);
  }

  /// Skips over a field of [wire] type the caller does not care about.
  void skipField(int wire) {
    switch (wire) {
      case 0:
        readVarint();
      case 1:
        _pos += 8;
      case 2:
        message().rest();
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported protobuf wire type $wire');
    }
    if (_pos > _end) throw const FormatException('truncated protobuf');
  }

  /// Reads one 64-bit varint (values beyond 63 bits wrap, as int64).
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _end) throw const FormatException('truncated varint');
      final b = bytes[_pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
      if (shift > 63) {
        throw const FormatException('varint too long');
      }
    }
    return result;
  }

  /// Reads one sint64 (zigzag) value.
  int readSint() {
    final v = readVarint();
    return (v >> 1) ^ -(v & 1);
  }

  /// Reads a packed repeated field, applying [add] to each value.
  void readPackedSint(void Function(int) add) {
    final sub = message();
    while (!sub.done) {
      add(sub.readSint());
    }
  }

  void readPackedUint32(List<int> out) {
    final sub = message();
    while (!sub.done) {
      out.add(sub.readVarint());
    }
  }
}
