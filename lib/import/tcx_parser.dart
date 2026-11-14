import 'dart:convert' show utf8;

import 'package:xml/xml.dart';

import '../models/track.dart';
import 'track_parser.dart';

/// TCX (Garmin Training Center) parser: `<Activities>/<Activity>/<Lap>/<Track>`
/// and `<Courses>/<Course>/<Track>` structures.
class TcxParser implements TrackParser {
  @override
  String get format => 'TCX';

  @override
  bool accepts(List<int> bytes) {
    if (!looksLikeXml(bytes)) return false;
    return sniffHead(bytes).contains('TrainingCenterDatabase');
  }

  @override
  TrackData parse(List<int> bytes, {String? sourceFilename}) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(bytes));
    } on FormatException {
      throw const TrackParseException('TCX', 'not valid UTF-8');
    } on XmlException catch (e) {
      throw TrackParseException('TCX', e.message);
    }
    final root = doc.rootElement;
    if (root.localName != 'TrainingCenterDatabase') {
      throw TrackParseException('TCX', 'root element is <${root.localName}>');
    }

    final points = <TrackPoint>[];
    for (final trackNode in root.descendantElements
        .where((e) => e.localName == 'Track')) {
      for (final tp in trackNode.findElements('Trackpoint', namespaceUri: '*')) {
        final pos = tp.findElements('Position', namespaceUri: '*');
        if (pos.isEmpty) continue;
        final lat = _num(pos.first, 'LatitudeDegrees');
        final lon = _num(pos.first, 'LongitudeDegrees');
        if (lat == null || lon == null) continue;
        points.add(TrackPoint(
          lat: lat,
          lon: lon,
          ele: _num(tp, 'AltitudeMeters'),
          time: _dt(tp, 'Time'),
        ));
      }
    }
    if (points.isEmpty) {
      throw const TrackParseException('TCX', 'no track points found');
    }

    // <Id> is usually a timestamp URL or plain timestamp; as a display name
    // the source filename is friendlier when available.
    final id = _text(root, 'Activity', 'Id') ?? _text(root, 'Course', 'Name');
    final name = (sourceFilename != null && sourceFilename.isNotEmpty)
        ? baseName(sourceFilename)
        : (id != null && id.isNotEmpty ? id : baseName(sourceFilename));

    return TrackData(name: name, format: format, points: points);
  }
}

double? _num(XmlElement parent, String tag) {
  final e = parent.findElements(tag, namespaceUri: '*');
  if (e.isEmpty) return null;
  return double.tryParse(e.first.innerText.trim());
}

DateTime? _dt(XmlElement parent, String tag) {
  final e = parent.findElements(tag, namespaceUri: '*');
  if (e.isEmpty) return null;
  return DateTime.tryParse(e.first.innerText.trim());
}

String? _text(XmlElement parent, String childName, String grandchildName) {
  for (final child
      in parent.descendantElements.where((e) => e.localName == childName)) {
    final g = child.findElements(grandchildName, namespaceUri: '*');
    if (g.isNotEmpty) {
      final t = g.first.innerText.trim();
      if (t.isNotEmpty) return t;
    }
  }
  return null;
}
