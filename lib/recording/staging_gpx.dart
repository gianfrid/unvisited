/// Incremental GPX 1.1 staging writer for live recording.
///
/// The contract to process death: every accepted point is appended with
/// its segment closed on pauses and fix loss, and flushed to the sink on
/// a short cadence, so a killed session leaves a file that is at worst a
/// complete GPX minus the closing tags of the last segment — [salvageGpx]
/// repairs exactly that and the repaired bytes re-import through the
/// unified pipeline like any other GPX (writer fixtures feed the reader's
/// tests; the round-trip is a tested invariant).
///
/// The GPX 1.1 schema (https://www.topografix.com/GPX/1/1) fixes the
/// element order inside a point: `<ele>` before `<time>`. GPX is chosen
/// over FIT because a pure-Dart FIT writer would be new code with zero
/// reuse, while this file's output feeds the app's own GPX parser
/// directly.
library;

/// Where the staged GPX bytes go. `dart:io`-backed for the app (slice 2
/// wires the app root), in-memory for the unit tests — same code path.
///
/// [flush] returns a [Future] and [finalize] awaits it: an un-awaited
/// flush binds the underlying IOSink, and a `close()` arriving while the
/// sink is bound throws (Bad state). The await is what keeps the loss
/// window from outliving the finalize.
abstract class StageSink {
  void write(String s);
  Future<void> flush();
  void close();
}

/// A [StageSink] over a [StringSink]; flushes are bookkeeping only.
class MemoryStageSink implements StageSink {
  final StringBuffer buffer = StringBuffer();
  int flushes = 0;
  bool closed = false;

  @override
  void write(String s) {
    if (closed) throw StateError('stage sink already closed');
    buffer.write(s);
  }

  @override
  Future<void> flush() async => flushes++;

  @override
  void close() => closed = true;
}

/// Writes a GPX 1.1 file incrementally: header + one open `<trkseg>` as
/// soon as the first point arrives, a closed segment boundary on every
/// [breakSegment], and the closing tags only on [finalize].
class GpxStageWriter {
  GpxStageWriter(this._sink, {required String name})
      : _name = _escape(name);

  static const _header = '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<gpx version="1.1" creator="unvisited" '
      'xmlns="http://www.topografix.com/GPX/1/1">\n<trk><name>';

  final StageSink _sink;
  final String _name;
  bool _headerWritten = false;
  bool _segmentOpen = false;
  int _points = 0;

  /// Appends one accepted fix as a `<trkpt>`. First call writes the
  /// header and opens the first segment; after a [breakSegment] (pause,
  /// fix loss) the next point reopens a segment.
  void appendPoint({
    required double lat,
    required double lon,
    required DateTime time,
    double? ele,
  }) {
    if (!_headerWritten) {
      _sink.write('$_header$_name</name>\n<trkseg>\n');
      _headerWritten = true;
      _segmentOpen = true;
    } else if (!_segmentOpen) {
      _sink.write('<trkseg>\n');
      _segmentOpen = true;
    }
    // Schema order: ele before time. Coordinates fixed to 6 decimals
    // (GPS resolution); elevation to centimeters.
    _sink.write('<trkpt lat="${lat.toStringAsFixed(6)}" '
        'lon="${lon.toStringAsFixed(6)}">\n');
    if (ele != null) _sink.write('<ele>${ele.toStringAsFixed(2)}</ele>\n');
    _sink.write('<time>${time.toUtc().toIso8601String()}</time>\n'
        '</trkpt>\n');
    _points++;
  }

  /// Closes the open segment; the next [appendPoint] opens a new one.
  /// The pause/fix-loss semantics live here: in GPX, a `<trkseg>` break
  /// means exactly "recording was interrupted between these points".
  void breakSegment() {
    if (_segmentOpen) {
      _sink.write('</trkseg>\n');
      _segmentOpen = false;
    }
  }

  /// Writes the closing tags. Idempotent; the awaited flush keeps the
  /// loss window from outliving the finalize, and the file is complete
  /// and closed afterwards.
  Future<void> finalize() async {
    if (_finalized || !_headerWritten) return; // No point, nothing to close.
    _finalized = true;
    breakSegment();
    _sink.write('</trk>\n</gpx>\n');
    await _sink.flush();
    _sink.close();
  }

  bool _finalized = false;

  int get pointCount => _points;
}

/// Repairs the file of a session killed mid-recording into valid GPX the
/// unified pipeline can import: anything after the last complete `</trkpt>`
/// (or `</trkseg>`) is a half-written point and is cut, then the missing
/// closers are appended. Returns null for files that contain no complete
/// point at all (a session killed before its first flush) — there is
/// nothing worth salvaging.
String? salvageGpx(String bytes) {
  const pointEnd = '</trkpt>';
  const segmentEnd = '</trkseg>';
  final lastPoint = bytes.lastIndexOf(pointEnd);
  if (lastPoint < 0) return null;
  final kept = lastPoint + pointEnd.length;
  var body = bytes.substring(0, kept);
  if (!body.contains(segmentEnd) ||
      body.lastIndexOf(segmentEnd) + segmentEnd.length <
          body.lastIndexOf(pointEnd)) {
    body += '\n</trkseg>';
  }
  body += '\n</trk>\n</gpx>\n';
  return body;
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
