import '../models/track.dart';

/// Thrown when a track file cannot be parsed in the given format.
class TrackParseException implements Exception {
  const TrackParseException(this.format, this.reason);

  final String format;
  final String reason;

  @override
  String toString() => 'Could not parse $format: $reason';
}

/// A parsing error that is expected for a subset of files, e.g. FIT
/// `monitoring` files which are intentionally skipped (not an error).
class UnsupportedTrackException implements Exception {
  const UnsupportedTrackException(this.format, this.reason);

  final String format;
  final String reason;

  @override
  String toString() => 'Unsupported $format file: $reason';
}

abstract class TrackParser {
  /// Format label: `GPX`, `FIT`, `KMZ` or `TCX`.
  String get format;

  /// True if [bytes] look like this format. Used for content sniffing,
  /// independent of file extensions.
  bool accepts(List<int> bytes);

  /// Parses [bytes] into a [TrackData].
  ///
  /// [sourceFilename] may be null (e.g. for share-intent streams) and is
  /// only used as a name fallback.
  TrackData parse(List<int> bytes, {String? sourceFilename});
}

/// Strips a common extension from [name] for display purposes.
String baseName(String? name) {
  if (name == null || name.isEmpty) return 'Unnamed track';
  final lastSep = name.lastIndexOf('/');
  var n = lastSep >= 0 ? name.substring(lastSep + 1) : name;
  final dot = n.lastIndexOf('.');
  if (dot > 0) n = n.substring(0, dot);
  return n;
}

/// Decodes the first bytes of [bytes] for cheap content sniffing. Bytes are
/// decoded 1:1 as code units; that mangles multibyte UTF-8 into mojibake but
/// is fine for finding ASCII markers like `<gpx` or `.FIT`.
String sniffHead(List<int> bytes, [int maxChars = 2048]) =>
    String.fromCharCodes(bytes.take(maxChars));

/// Cheap sniff that we're looking at XML at all (vs. binary FIT/KMZ).
bool looksLikeXml(List<int> bytes) {
  var i = 0;
  // Skip a UTF-8 BOM.
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    i = 3;
  }
  // Skip leading whitespace.
  while (i < bytes.length &&
      (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D)) {
    i++;
  }
  if (i >= bytes.length) return false;
  if (bytes[i] != 0x3C /* < */) return false;
  // Whatever follows the '<' must start a printable tag name, not binary.
  final next = i + 1 < bytes.length ? bytes[i + 1] : 0;
  return (next >= 0x41 && next <= 0x7A) || next == 0x3F /* ? */ || next == 0x21 /* ! */;
}
