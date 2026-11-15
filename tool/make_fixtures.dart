// ignore_for_file: avoid_print
// Generates binary test fixtures (FIT files + KMZ archive) into
// test/fixtures/. Run with: dart tool/make_fixtures.dart
//
// The fixtures stay checked in so tests never depend on this tool at test
// time; re-run it only when a fixture needs to change.
//
// NOTE on the file-level CRC: this generator writes a conventional forward
// CRC-16/XMODEM; the parser deliberately does not hard-verify CRCs because
// truncated files must be tolerated (AGENTS.md).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:unvisited/recording/staging_gpx.dart';

const fitEpoch = 631065600; // 1989-12-31T00:00:00Z

final rideStart =
    DateTime.parse('2024-05-01T08:00:00Z').millisecondsSinceEpoch ~/ 1000 -
    fitEpoch;

int semicircles(double deg) =>
    (deg * 2147483648.0 / 180.0).round() & 0x7FFFFFFF;

class FitWriter {
  final List<int> _bytes = [];

  /// Appends raw message bytes (used to simulated truncated writes).
  void appendBytes(List<int> b) => _bytes.addAll(b);

  void definition(
    int local,
    int globalMsg,
    List<List<int>> fields /* [num, size, baseType] */,
  ) {
    _bytes.add(0x40 | local);
    _bytes.addAll([0, 0]); // reserved, little-endian architecture
    _bytes.addAll([globalMsg & 0xFF, (globalMsg >> 8) & 0xFF]);
    _bytes.add(fields.length);
    for (final f in fields) {
      _bytes.addAll(f);
    }
  }

  void data(int local, List<int> payload) {
    _bytes.add(local); // normal header, no compressed timestamp
    _bytes.addAll(payload);
  }

  /// Compressed-timestamp data message (localType must be < 4).
  void compressedData(int localType, int timeOffset, List<int> payload) {
    assert(localType <= 3);
    assert(timeOffset >= 0 && timeOffset < 0x20);
    _bytes.add(0x80 | (localType << 5) | timeOffset);
    _bytes.addAll(payload);
  }

  Uint8List build() {
    final body = _bytes;
    final header = <int>[
      0x0E, // header size 14
      0x10, // protocol version 1.0
      0xE1, 0x07, // profile version (arbitrary, matches Garmin-ish layout)
      ..._u32(body.length),
      0x2E, 0x46, 0x49, 0x54, // ".FIT"
    ];
    var crc = fitCrc(header);
    crc = fitCrc(body, crc);
    final out = [...header, crc & 0xFF, (crc >> 8) & 0xFF, ...body];
    return Uint8List.fromList(out);
  }

  List<int> _u32(int v) => [
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ];
}

int fitCrc(List<int> bytes, [int crc = 0]) {
  for (final b in bytes) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      if (crc & 0x8000 != 0) {
        crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
    }
  }
  return crc;
}

List<int> u32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

// ---- activity FIT: Berlin ride with GPS loss (dropped position records)
//      and mixed absolute / compressed timestamps ----
Uint8List activityRide({bool truncated = false, int cutAfterRecord = 3}) {
  final w = FitWriter();
  // local 0: file_id (global 0): time(1,u32), manufacturer(2,u16), type(6,u8)
  w.definition(0, 0, [
    [1, 4, 0x06],
    [2, 2, 0x04],
    [6, 1, 0x00],
  ]);
  w.data(0, [...u32(rideStart), 0x01, 0x00, 0x04 /* activity */]);

  // local 1: record (global 20): timestamp(253,u32), lat(0,s32), lon(1,s32)
  w.definition(1, 20, [
    [253, 4, 0x06],
    [0, 4, 0x05],
    [1, 4, 0x05],
  ]);
  // local 2: record without position (GPS loss / pause, smart recording)
  w.definition(2, 20, [
    [253, 4, 0x06],
  ]);
  // local 3: record positioned via a compressed-timestamp header:
  // the header carries the time offset, so the body holds position only.
  w.definition(3, 20, [
    [0, 4, 0x05],
    [1, 4, 0x05],
  ]);

  final coords = <List<double>>[
    [52.52000, 13.40500],
    [52.52100, 13.40600],
    [52.52200, 13.40700],
    [52.52300, 13.40850],
    [52.52400, 13.41000],
    [52.52500, 13.41150],
  ];
  for (var i = 0; i < coords.length; i++) {
    final lat = semicircles(coords[i][0]);
    final lon = semicircles(coords[i][1]);
    if (truncated && i == cutAfterRecord) {
      // The cut record: header byte plus a position payload cut in half
      // (the longitude never arrived — battery death mid-message).
      w.appendBytes([0x03]); // data message for local type 3
      w.appendBytes(u32(lat));
      break;
    }
    if (i == 2) {
      // GPS dropped: timestamp-only record via local type 2.
      w.data(2, u32(rideStart + i * 4));
    } else if (i == 0 || i == 3) {
      // Records with an absolute timestamp on the wire; they anchor the
      // reference for the compressed-timestamp records in between.
      w.data(1, [...u32(rideStart + i * 4), ...u32(lat), ...u32(lon)]);
    } else {
      // 4s smart-recording interval: compressed header whose low 5 bits
      // are the absolute timestamp's seconds & 0x1F.
      final offset = (rideStart + i * 4) & 0x1F;
      w.compressedData(3, offset, [...u32(lat), ...u32(lon)]);
    }
  }
  return w.build();
}

// ---- truncated activity FIT: battery death mid-ride, cut inside a
//      record, no session/summary block and no file CRC ----
Uint8List truncatedRide() => activityRide(truncated: true, cutAfterRecord: 4);

// ---- monitoring FIT: type 32, daily health metrics ----
Uint8List monitoringFile() {
  final w = FitWriter();
  w.definition(0, 0, [
    [1, 4, 0x06],
    [2, 2, 0x04],
    [5, 2, 0x04],
    [6, 1, 0x00],
  ]);
  w.data(0, [...u32(rideStart), 0xE2, 0x02, 0x01, 0x00, 32 /* monitoring */]);
  // One monitoring message so the file is structurally complete.
  return w.build();
}

// ---- OpenTracks-style KML (gx:Track), also zipped as KMZ ----
String opentracksKml() {
  final track = <double>[52.52, 13.405, 52.521, 13.406, 52.522, 13.407];
  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buffer.writeln(
    '<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">',
  );
  buffer.writeln('  <Document>');
  buffer.writeln('    <name>Afternoon ride</name>');
  buffer.writeln('    <Placemark>');
  buffer.writeln('      <name>Afternoon ride</name>');
  buffer.writeln('      <gx:Track>');
  for (var i = 0; i < track.length; i += 2) {
    final t = DateTime.parse('2024-05-01T15:0$i:00Z');
    buffer.writeln('        <when>${t.toIso8601String()}</when>');
    buffer.writeln(
      '        <gx:coord>${track[i + 1]} ${track[i]} ${40 + i}</gx:coord>',
    );
  }
  buffer.writeln('      </gx:Track>');
  buffer.writeln('    </Placemark>');
  buffer.writeln('  </Document>');
  buffer.writeln('</kml>');
  return buffer.toString();
}

Uint8List opentracksKmz() {
  final content = Uint8List.fromList(opentracksKml().codeUnits);
  final archive = Archive();
  archive.add(ArchiveFile('doc.kml', content.length, content));
  archive.add(ArchiveFile('google-logo.png', 3, Uint8List.fromList([1, 2, 3])));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

// ---- OSM PBF: a tiny town exercising both node encodings, non-default
//      granularity/offsets, a way referencing nodes from a later block, and
//      both raw and zlib blobs (read by tool/pbf_reader.dart) ----

/// Minimal protobuf wire writer (what the OSM PBF fixture needs; the real
/// reader side is hand-written in tool/pbf_reader.dart).
class PbfWriter {
  final List<int> _bytes = [];

  void varint(int v) {
    assert(v >= 0, 'use sint() for signed values');
    var x = v;
    while (x > 0x7f) {
      _bytes.add((x & 0x7f) | 0x80);
      x >>= 7;
    }
    _bytes.add(x);
  }

  /// sint32/sint64 field value (zigzag).
  void sint(int v) => varint(v >= 0 ? v << 1 : (-v << 1) - 1);

  void intField(int number, int v) {
    _field(number, 0);
    varint(v);
  }

  void sintField(int number, int v) {
    _field(number, 0);
    sint(v);
  }

  void string(int number, String s) => bytesField(number, utf8.encode(s));

  void bytesField(int number, List<int> b) {
    _field(number, 2);
    varint(b.length);
    _bytes.addAll(b);
  }

  void packedSint(int number, List<int> values) {
    final sub = PbfWriter();
    for (final v in values) {
      sub.sint(v);
    }
    bytesField(number, sub._bytes);
  }

  void packedUint32(int number, List<int> values) {
    final sub = PbfWriter();
    for (final v in values) {
      sub.varint(v);
    }
    bytesField(number, sub._bytes);
  }

  void _field(int number, int wire) => varint((number << 3) | wire);

  List<int> get bytes => _bytes;
}

/// One top-level PBF frame: length-prefixed BlobHeader + Blob around a
/// message payload (zlib-compressed when [compress]).
Uint8List pbfFrame(String type, List<int> payload, {bool compress = false}) {
  final blob = PbfWriter();
  if (compress) {
    blob.bytesField(3, zlib.encoder.convert(payload)); // zlib_data
  } else {
    blob.bytesField(1, payload); // raw
  }
  blob.intField(2, payload.length); // raw_size
  final header = PbfWriter()
    ..string(1, type)
    ..intField(3, blob.bytes.length); // datasize
  final h = header.bytes;
  final b = blob.bytes;
  return Uint8List.fromList([
    (h.length >> 24) & 0xFF,
    (h.length >> 16) & 0xFF,
    (h.length >> 8) & 0xFF,
    h.length & 0xFF,
    ...h,
    ...b,
  ]);
}

const pbfTown = (
  // Block A: plain nodes, granularity 100, no offsets (the proto defaults).
  aStrings: ['', 'highway', 'name', 'service', 'Weinbergsweg', 'footway'],
  // Block B: dense nodes, granularity 1000 with offsets (a real extract's
  // writer picks these; the reader must honor all three knobs).
  bStrings: ['', 'highway', 'name', 'primary', 'Torstraße', 'building', 'yes'],
);

({int id, double lat, double lon}) _pbfNode(int id, double lat, double lon) =>
    (id: id, lat: lat, lon: lon);

int _nanoRelative(double degrees, int granularity, int offset) =>
    ((degrees * 1e9).round() - offset) ~/ granularity;

/// A PrimitiveGroup of plain Node messages.
List<int> _pbfPlainNodes(
  List<({int id, double lat, double lon})> nodes,
  int granularity,
  int latOffset,
  int lonOffset,
) {
  final group = PbfWriter();
  for (final n in nodes) {
    final node = PbfWriter()
      ..sintField(1, n.id)
      ..sintField(8, _nanoRelative(n.lat, granularity, latOffset))
      ..sintField(9, _nanoRelative(n.lon, granularity, lonOffset));
    group.bytesField(1, node.bytes);
  }
  return group.bytes;
}

/// A PrimitiveGroup with one DenseNodes row set (ids/lat/lon delta-coded).
List<int> _pbfDenseNodes(
  List<({int id, double lat, double lon})> nodes,
  int granularity,
  int latOffset,
  int lonOffset,
) {
  final relLat = [
    for (final n in nodes) _nanoRelative(n.lat, granularity, latOffset),
  ];
  final relLon = [
    for (final n in nodes) _nanoRelative(n.lon, granularity, lonOffset),
  ];
  final dense = PbfWriter()
    ..packedSint(1, [
      for (var i = 0; i < nodes.length; i++)
        nodes[i].id - (i == 0 ? 0 : nodes[i - 1].id),
    ])
    ..packedSint(8, [
      for (var i = 0; i < relLat.length; i++)
        relLat[i] - (i == 0 ? 0 : relLat[i - 1]),
    ])
    ..packedSint(9, [
      for (var i = 0; i < relLon.length; i++)
        relLon[i] - (i == 0 ? 0 : relLon[i - 1]),
    ])
    // keys_vals: one 0 terminator per untagged node.
    ..packedUint32(10, [for (var i = 0; i < nodes.length; i++) 0]);
  final group = PbfWriter()..bytesField(2, dense.bytes);
  return group.bytes;
}

/// A PrimitiveGroup of Way messages (tags as string-table indices, refs
/// delta-coded).
List<int> _pbfWays(
  List<({int id, List<int> keys, List<int> vals, List<int> refs})> ways,
) {
  final group = PbfWriter();
  for (final w in ways) {
    final way = PbfWriter()
      ..intField(1, w.id)
      ..packedUint32(2, w.keys)
      ..packedUint32(3, w.vals);
    var pos = 0;
    final deltas = <int>[];
    for (final ref in w.refs) {
      deltas.add(ref - pos);
      pos = ref;
    }
    way.packedSint(8, deltas);
    group.bytesField(3, way.bytes);
  }
  return group.bytes;
}

/// A PrimitiveBlock payload from string table + groups + block scalars.
List<int> _pbfBlock({
  required List<String> strings,
  required int granularity,
  required int latOffset,
  required int lonOffset,
  required List<List<int>> groups,
}) {
  final table = PbfWriter();
  for (final s in strings) {
    table.string(1, s);
  }
  final block = PbfWriter()..bytesField(1, table.bytes);
  for (final g in groups) {
    block.bytesField(2, g);
  }
  block
    ..sintField(17, granularity)
    ..intField(19, latOffset)
    ..intField(20, lonOffset);
  return block.bytes;
}

Uint8List townOsmPbf() {
  // OSMHeader: the required-features declaration real files carry.
  final header = PbfWriter()
    ..string(4, 'OsmSchema-V0.6')
    ..string(4, 'DenseNodes')
    ..string(16, 'unvisited-make_fixtures');

  const aGranularity = 100;
  const bGranularity = 1000;
  const bLatOffset = 52000000000; // 52 degrees
  const bLonOffset = 13000000000; // 13 degrees

  // Way 100 (service, Weinbergsweg): nodes 1-3 in this block.
  // Way 103 (footway): references node 999, which does not exist anywhere —
  // the missing-node drop path.
  final blockA = _pbfBlock(
    strings: pbfTown.aStrings,
    granularity: aGranularity,
    latOffset: 0,
    lonOffset: 0,
    groups: [
      _pbfPlainNodes(
        [
          _pbfNode(1, 52.5280, 13.4020),
          _pbfNode(2, 52.5288, 13.4030),
          _pbfNode(3, 52.5250, 13.4000),
        ],
        aGranularity,
        0,
        0,
      ),
      _pbfWays([
        (id: 100, keys: [1, 2], vals: [3, 4], refs: [1, 2, 3]),
        (id: 103, keys: [1], vals: [5], refs: [2, 999]),
      ]),
    ],
  );

  // Way 101 (primary, Torstraße) is kept; way 102 (building=yes) is not a
  // road and must be filtered out by the highway-tag choice.
  final blockB = _pbfBlock(
    strings: pbfTown.bStrings,
    granularity: bGranularity,
    latOffset: bLatOffset,
    lonOffset: bLonOffset,
    groups: [
      _pbfDenseNodes(
        [
          _pbfNode(4, 52.5255, 13.4010),
          _pbfNode(5, 52.5260, 13.4020),
          _pbfNode(6, 52.5265, 13.4030),
          _pbfNode(7, 52.5300, 13.4100),
          _pbfNode(8, 52.5302, 13.4102),
          _pbfNode(9, 52.5304, 13.4104),
        ],
        bGranularity,
        bLatOffset,
        bLonOffset,
      ),
      _pbfWays([
        (id: 101, keys: [1, 2], vals: [3, 4], refs: [3, 4, 5]),
        (id: 102, keys: [5], vals: [6], refs: [7, 8, 9]),
      ]),
    ],
  );

  final frames = [
    pbfFrame('OSMHeader', header.bytes),
    pbfFrame('OSMData', blockA),
    pbfFrame('OSMData', blockB, compress: true),
  ];
  return Uint8List.fromList([for (final f in frames) ...f]);
}

// ---- recording GPX round-trip: written by the app's own stage writer
//      (two segments — a pause breaks them), re-imported by
//      test/recording_session_test.dart through the unified pipeline
Uint8List recordedRideGpx() {
  final sink = MemoryStageSink();
  final writer = GpxStageWriter(sink, name: 'Evening walk');
  final base = DateTime.parse('2024-05-01T18:00:00Z');
  var second = 0;
  void point(double lat, double ele) {
    writer.appendPoint(
      lat: lat,
      lon: 13.4050,
      time: base.add(Duration(seconds: second)),
      ele: ele,
    );
    second += 2;
  }

  // Walking north along the Greenwich meridian (~11.1 m per step), then a
  // pause splits the recorded ride into two `<trkseg>`s.
  point(52.5200, 42.0);
  point(52.5201, 42.7);
  point(52.5202, 43.3);
  writer.breakSegment();
  point(52.5203, 44.0);
  point(52.5204, 44.5);
  // MemoryStageSink's close is synchronous, so the unclosed buffer below
  // never actually happens — the fixture is a complete GPX file.
  writer.finalize();
  return Uint8List.fromList(sink.buffer.toString().codeUnits);
}

void main() {
  final dir = Directory('test/fixtures');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  _write('test/fixtures/activity_ride.fit', activityRide());
  _write('test/fixtures/truncated_ride.fit', truncatedRide());
  _write('test/fixtures/monitoring.fit', monitoringFile());
  _write('test/fixtures/afternoon_ride.kmz', opentracksKmz());
  _write('test/fixtures/afternoon_ride.kml',
      Uint8List.fromList(opentracksKml().codeUnits));
  _write('test/fixtures/town.osm.pbf', townOsmPbf());
  _write('test/fixtures/recorded_ride.gpx', recordedRideGpx());
  print('fixtures written');
}

void _write(String path, Uint8List bytes) {
  File(path).writeAsBytesSync(bytes);
  print('  $path (${bytes.length} bytes)');
}
