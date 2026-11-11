import '../models/track.dart';
import 'fit_parser.dart';
import 'gpx_parser.dart';
import 'kmz_parser.dart';
import 'tcx_parser.dart';
import 'track_parser.dart';

export 'track_parser.dart' show UnsupportedTrackException, TrackParseException;

/// The one unified import pipeline every source (SAF folder, share intent,
/// file picker) flows through.
///
/// Format priority per AGENTS.md: GPX first, then FIT, then KMZ, then TCX
/// (plain KML handled alongside KMZ — OpenTracks exports both).
/// Detection is content-based (magic bytes / root element); extensions are
/// never the source of truth, so every source with any naming convention
/// funnels through identically.
class TrackImporter {
  TrackImporter({List<TrackParser>? parsers})
      : _parsers = parsers ??
            [
              GpxParser(),
              FitParser(),
              KmzParser(),
              TcxParser(),
              KmlParser(KmzParser()),
            ];

  final List<TrackParser> _parsers;

  /// Detects which parser accepts [bytes], honoring format priority.
  TrackParser? detect(List<int> bytes) {
    for (final p in _parsers) {
      if (p.accepts(bytes)) return p;
    }
    return null;
  }

  /// Parses [bytes] into a [TrackData]. Throws [TrackParseException] when
  /// no format succeeds, and [UnsupportedTrackException] for
  /// recognized-but-skipped files (e.g. FIT monitoring).
  TrackData import(List<int> bytes, {String? filename}) {
    TrackParseException? lastError;
    for (final p in _parsers) {
      if (!p.accepts(bytes)) continue;
      try {
        return p.parse(bytes, sourceFilename: filename);
      } on UnsupportedTrackException {
        rethrow;
      } on TrackParseException catch (e) {
        lastError = e; // matched content but failed to parse: try the rest
      }
    }
    if (lastError != null) throw lastError;
    throw TrackParseException('?',
        'unrecognized track format${filename == null ? '' : ' ($filename)'}');
  }
}
