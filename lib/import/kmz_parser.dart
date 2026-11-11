import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../models/track.dart';
import 'track_parser.dart';

/// KMZ (zipped KML) parser. Handles the two KML track layouts that GPS
/// recorders produce:
///  * `<gx:Track>` with paired `<when>` / `<gx:coord>` (OpenTracks)
///  * `<LineString><coordinates>` triples `lon,lat[,alt]` (Google exports)
///
/// NOTE: KML coordinates are longitude-first, unlike GPX/FIT.
class KmzParser implements TrackParser {
  @override
  String get format => 'KMZ';

  @override
  bool accepts(List<int> bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x50 && bytes[1] == 0x4B && // ZIP magic "PK"
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);
  }

  @override
  TrackData parse(List<int> bytes, {String? sourceFilename}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw TrackParseException('KMZ', 'not a valid ZIP file: $e');
    }

    // Prefer doc.kml, then any .kml entry, shortest path first.
    final kmlEntries = archive.files
        .where((f) => f.name.toLowerCase().endsWith('.kml'))
        .toList()
      ..sort((a, b) {
        final aDoc = a.name.toLowerCase().endsWith('doc.kml') ? 0 : 1;
        final bDoc = b.name.toLowerCase().endsWith('doc.kml') ? 0 : 1;
        return aDoc != bDoc
            ? aDoc - bDoc
            : a.name.length.compareTo(b.name.length);
      });
    if (kmlEntries.isEmpty) {
      throw const TrackParseException('KMZ', 'no .kml entry found in archive');
    }

    final kmlText = String.fromCharCodes(kmlEntries.first.content);
    final points = parseKml(kmlText);
    if (points.isEmpty) {
      throw const TrackParseException(
          'KMZ', 'no coordinates found in KML document');
    }

    return TrackData(
      name: kmlDisplayName(kmlText) ?? baseName(sourceFilename),
      format: format,
      points: points,
    );
  }

  /// Parses KML text into points; exposed for sharing with plain `.kml`
  /// imports later.
  List<TrackPoint> parseKml(String kmlText) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(kmlText);
    } on XmlException catch (e) {
      throw TrackParseException('KMZ', 'invalid KML: ${e.message}');
    }
    final root = doc.rootElement;
    final points = <TrackPoint>[];
    for (final track in root.descendantElements
        .where((e) => e.localName == 'Track' || e.localName == 'gx:Track'.split(':').last)) {
      _parseGxTrack(track, points);
    }
    if (points.isEmpty) {
      for (final node in root.descendantElements
          .where((e) => e.localName == 'LineString')) {
        _parseLineString(node, points);
      }
    }
    return points;
  }

  void _parseGxTrack(XmlElement track, List<TrackPoint> out) {
    final whens = track.findElements('when', namespaceUri: '*').map((e) {
      return DateTime.tryParse(e.innerText.trim());
    }).toList();
    final coords =
        track.findElements('coord', namespaceUri: '*').map((e) {
      return e.innerText.trim().split(RegExp(r'\s+'));
    }).toList();
    for (var i = 0; i < coords.length; i++) {
      final c = coords[i];
      if (c.length < 2) continue;
      final lon = double.tryParse(c[0]);
      final lat = double.tryParse(c[1]);
      if (lat == null || lon == null) continue;
      final ele = c.length >= 3 ? double.tryParse(c[2]) : null;
      final time = i < whens.length ? whens[i] : null;
      out.add(TrackPoint(lat: lat, lon: lon, ele: ele, time: time));
    }
  }

  void _parseLineString(XmlElement node, List<TrackPoint> out) {
    for (final coordsNode in node.findElements('coordinates', namespaceUri: '*')) {
      for (final token in coordsNode.innerText.trim().split(RegExp(r'\s+'))) {
        final parts = token.split(',');
        if (parts.length < 2) continue;
        final lon = double.tryParse(parts[0]);
        final lat = double.tryParse(parts[1]);
        if (lat == null || lon == null) continue;
        final ele =
            parts.length >= 3 ? double.tryParse(parts[2]) : null;
        out.add(TrackPoint(lat: lat, lon: lon, ele: ele));
      }
    }
  }

  String? kmlDisplayName(String kmlText) {
    try {
      final doc = XmlDocument.parse(kmlText);
      final root = doc.rootElement;
      for (final tag in const ['Document', 'Placemark']) {
        for (final node in root.descendantElements
            .where((e) => e.localName == tag)) {
          final n = node.findElements('name', namespaceUri: '*');
          if (n.isNotEmpty && n.first.innerText.trim().isNotEmpty) {
            final t = n.first.innerText.trim();
            if (t.toLowerCase() != 'doc.kml' &&
                t.toLowerCase() != 'kml document' &&
                t.toLowerCase() != 'track') {
              return t;
            }
          }
        }
      }
    } on XmlException {
      // fall through to null
    }
    return null;
  }
}

/// Plain (unzipped) KML — OpenTracks offers KML exports next to KMZ/GPX.
/// Reuses the KMZ parser's coordinate handling.
class KmlParser implements TrackParser {
  KmlParser(this._kmz);

  final KmzParser _kmz;

  @override
  String get format => 'KML';

  @override
  bool accepts(List<int> bytes) {
    return looksLikeXml(bytes) && sniffHead(bytes).contains('<kml');
  }

  @override
  TrackData parse(List<int> bytes, {String? sourceFilename}) {
    final text = String.fromCharCodes(bytes);
    final points = _kmz.parseKml(text);
    if (points.isEmpty) {
      throw const TrackParseException(
          'KML', 'no coordinates found in KML document');
    }
    return TrackData(
      name: _kmz.kmlDisplayName(text) ?? baseName(sourceFilename),
      format: format,
      points: points,
    );
  }
}
