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

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

const fitEpoch = 631065600; // 1989-12-31T00:00:00Z

final rideStart =
    DateTime.parse('2024-05-01T08:00:00Z').millisecondsSinceEpoch ~/ 1000 -
        fitEpoch;

int semicircles(double deg) => (deg * 2147483648.0 / 180.0).round() & 0x7FFFFFFF;

class FitWriter {
  final List<int> _bytes = [];

  /// Appends raw message bytes (used to simulated truncated writes).
  void appendBytes(List<int> b) => _bytes.addAll(b);

  void definition(int local,
      int globalMsg, List<List<int>> fields /* [num, size, baseType] */) {
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

  List<int> _u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
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

List<int> u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

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

// ---- OpenTracks-style KMZ (zipped KML with gx:Track) ----
Uint8List opentracksKmz() {
  final track = <double>[52.52, 13.405, 52.521, 13.406, 52.522, 13.407];
  final buffer = StringBuffer();
  buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buffer.writeln(
      '<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">');
  buffer.writeln('  <Document>');
  buffer.writeln('    <name>Afternoon ride</name>');
  buffer.writeln('    <Placemark>');
  buffer.writeln('      <name>Afternoon ride</name>');
  buffer.writeln('      <gx:Track>');
  for (var i = 0; i < track.length; i += 2) {
    final t = DateTime.parse('2024-05-01T15:0$i:00Z');
    buffer.writeln('        <when>${t.toIso8601String()}</when>');
    buffer.writeln(
        '        <gx:coord>${track[i + 1]} ${track[i]} ${40 + i}</gx:coord>');
  }
  buffer.writeln('      </gx:Track>');
  buffer.writeln('    </Placemark>');
  buffer.writeln('  </Document>');
  buffer.writeln('</kml>');

  final archive = Archive();
  final content = Uint8List.fromList(buffer.toString().codeUnits);
  archive.add(ArchiveFile('doc.kml', content.length, content));
  archive.add(ArchiveFile('google-logo.png', 3, Uint8List.fromList([1, 2, 3])));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  final dir = Directory('test/fixtures');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  _write('test/fixtures/activity_ride.fit', activityRide());
  _write('test/fixtures/truncated_ride.fit', truncatedRide());
  _write('test/fixtures/monitoring.fit', monitoringFile());
  _write('test/fixtures/afternoon_ride.kmz', opentracksKmz());
  print('fixtures written');
}

void _write(String path, Uint8List bytes) {
  File(path).writeAsBytesSync(bytes);
  print('  $path (${bytes.length} bytes)');
}
