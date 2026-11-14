import 'dart:convert' show utf8;

import 'package:xml/xml.dart';

import '../models/track.dart';
import 'track_parser.dart';

/// GPX 1.0/1.1 parser: `<trk>/<trkseg>/<trkpt>` segments (all merged into
/// one point list), falling back to `<rte>/<rtept>` routes.
class GpxParser implements TrackParser {
  @override
  String get format => 'GPX';

  @override
  bool accepts(List<int> bytes) {
    if (!looksLikeXml(bytes)) return false;
    return sniffHead(bytes).contains('<gpx');
  }

  @override
  TrackData parse(List<int> bytes, {String? sourceFilename}) {
    final String text;
    try {
      text = _text(bytes);
    } catch (_) {
      throw const TrackParseException('GPX', 'not valid UTF-8');
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } on XmlException catch (e) {
      throw TrackParseException('GPX', e.message);
    }
    final root = doc.rootElement;
    if (root.localName != 'gpx') {
      throw TrackParseException('GPX', 'root element is <${root.localName}>');
    }

    var name = _childText(root, 'trk', 'name')?.trim();
    name = (name == null || name.isEmpty) ? null : name;

    final points = <TrackPoint>[];
    for (final seg in _segments(root)) {
      for (final node in seg.findElements('trkpt', namespaceUri: '*')) {
        final p = _point(node);
        if (p != null) points.add(p);
      }
    }
    if (points.isEmpty) {
      for (final rte in root.findElements('rte', namespaceUri: '*')) {
        for (final node in rte.findElements('rtept', namespaceUri: '*')) {
          final p = _point(node);
          if (p != null) points.add(p);
        }
      }
    }

    if (points.isEmpty) {
      throw const TrackParseException('GPX', 'no track points found');
    }

    return TrackData(
      name: name ?? baseName(sourceFilename),
      format: format,
      points: points,
    );
  }

  Iterable<XmlElement> _segments(XmlElement root) {
    final segs = root
        .findElements('trk', namespaceUri: '*')
        .expand((trk) => trk.findElements('trkseg', namespaceUri: '*'));
    if (segs.isNotEmpty) return segs;
    // Segments without explicit <trkseg> wrapper.
    return root.findElements('trk', namespaceUri: '*');
  }

  TrackPoint? _point(XmlElement node) {
    final lat = double.tryParse(node.getAttribute('lat') ?? '');
    final lon = double.tryParse(node.getAttribute('lon') ?? '');
    if (lat == null || lon == null) return null;
    return TrackPoint(
      lat: lat,
      lon: lon,
      ele: _double(node, 'ele'),
      time: _dateTime(node, 'time'),
    );
  }
}

String? _childText(XmlElement parent, String childName, String grandchildName) {
  for (final child in parent.findElements(childName, namespaceUri: '*')) {
    final g = child.findElements(grandchildName, namespaceUri: '*');
    if (g.isNotEmpty) {
      final t = g.first.innerText.trim();
      if (t.isNotEmpty) return t;
    }
  }
  return null;
}

double? _double(XmlElement node, String tag) {
  final t = node.findElements(tag, namespaceUri: '*');
  if (t.isEmpty) return null;
  return double.tryParse(t.first.innerText.trim());
}

DateTime? _dateTime(XmlElement node, String tag) {
  final t = node.findElements(tag, namespaceUri: '*');
  if (t.isEmpty) return null;
  return DateTime.tryParse(t.first.innerText.trim());
}

/// File bytes to text: UTF-8 — every XML producer in scope (OpenTracks,
/// Garmin, Strava, the app's own stage writer) writes UTF-8, and decoding
/// 1:1 as code units like the ASCII sniffer does would mangle every
/// non-ASCII track name inside the document. Throws FormatException on
/// bytes that are not valid UTF-8 (the parser maps it).
String _text(List<int> bytes) => utf8.decode(bytes);
