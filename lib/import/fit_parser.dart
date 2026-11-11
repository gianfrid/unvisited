import '../models/track.dart';
import 'track_parser.dart';

/// Pure-Dart FIT (Flexible and Interoperable Data Transfer) parser.
///
/// Constraints implemented here (AGENTS.md):
///  * The FIT File Id message decides: `type` value 4 = activity (import),
///    32 = monitoring (skipped). Never branch on filename or folder paths.
///  * Truncated files (missing session/summary block, e.g. battery death
///    mid-ride) are tolerated: parsing stops at end-of-data, points seen so
///    far are kept.
///  * Smart Recording's variable intervals and pause events need no special
///    handling — pause records carry no position and are dropped.
///  * Chained FIT segments (header + data blocks repeated) are scanned.
class FitParser implements TrackParser {
  @override
  String get format => 'FIT';

  static const _fileIdMessage = 0;
  static const _recordMessage = 20;
  static const _fileIdTypeField = 6; // file_id 'type' field number
  static const _fileTypeActivity = 4;
  static const _fileTypeMonitoring = 32;

  /// Last absolute FIT timestamp seen (seconds since the FIT epoch);
  /// the basis for expanding compressed-timestamp headers.
  int? _refSeconds;
  static const _fieldPositionLat = 0;
  static const _fieldPositionLon = 1;
  static const _fieldTimestamp = 253;

  /// FIT timestamps: seconds since 1989-12-31T00:00:00 UTC.
  static const _fitEpochSeconds = 631065600;
  static const _invalidTimestamp = 0xFFFFFFFF;
  static const _invalidCoord = 0x7FFFFFFF;
  static const _semicircleToDeg = 180.0 / 2147483648.0;

  @override
  bool accepts(List<int> bytes) {
    if (bytes.length < 12) return false;
    return bytes[8] == 0x2E &&
        bytes[9] == 0x46 &&
        bytes[10] == 0x49 &&
        bytes[11] == 0x54; // ".FIT"
  }

  @override
  TrackData parse(List<int> bytes, {String? sourceFilename}) {
    _refSeconds = null;
    final fileTypes = <int>{};
    final points = <TrackPoint>[];
    var sawHeader = false;
    var pos = 0;
    while (pos + 12 <= bytes.length && _isMagicAt(bytes, pos)) {
      sawHeader = true;
      final headerSize = bytes[pos];
      if (headerSize != 12 && headerSize != 14) {
        throw TrackParseException('FIT', 'unexpected header size $headerSize');
      }
      if (pos + headerSize > bytes.length) break; // truncated header
      final dataSize = _u16(bytes, pos + 4);
      final dataStart = pos + headerSize;
      final dataEnd = (dataStart + dataSize > bytes.length || dataSize == 0)
          ? bytes.length // truncated/lying data size: clamp
          : dataStart + dataSize;
      _readSegment(bytes, dataStart, dataEnd, points, fileTypes);
      pos = dataStart + dataSize;
    }
    if (!sawHeader) {
      throw const TrackParseException('FIT', 'missing .FIT header magic');
    }
    if (fileTypes.contains(_fileTypeMonitoring)) {
      throw const UnsupportedTrackException(
          'FIT', 'monitoring file (all-day health metrics) — skipped');
    }
    if (fileTypes.isNotEmpty && !fileTypes.contains(_fileTypeActivity)) {
      final types = fileTypes.toList()..sort();
      throw UnsupportedTrackException(
          'FIT', 'file id type ${types.join('/')} is not an activity');
    }
    if (points.isEmpty) {
      throw const TrackParseException('FIT', 'no record points found');
    }
    return TrackData(
      name: baseName(sourceFilename),
      format: format,
      points: points,
    );
  }

  static bool _isMagicAt(List<int> b, int pos) =>
      b[pos + 8] == 0x2E &&
      b[pos + 9] == 0x46 &&
      b[pos + 10] == 0x49 &&
      b[pos + 11] == 0x54;

  void _readSegment(
      List<int> b, int start, int end, List<TrackPoint> out, Set<int> types) {
    final defs = <int, _MessageDef>{};
    var pos = start;
    while (pos < end) {
      final header = b[pos++];
      if (header & 0x80 != 0) {
        // Compressed timestamp header: bits 6-5 local type, low 5 bits
        // time offset expanded against the last full timestamp.
        final def = defs[(header >> 5) & 0x03];
        if (def == null) break; // corrupt stream: stop cleanly
        DateTime? time;
        final ref = _refSeconds;
        if (ref != null) {
          var secs = (ref & 0xFFFFFFE0) + (header & 0x1F);
          if (secs < ref) secs += 0x20; // wrapped into the next 32s window
          time = DateTime.fromMillisecondsSinceEpoch(
              (_fitEpochSeconds + secs) * 1000,
              isUtc: true);
          _refSeconds = secs;
        }
        _handleData(def, b, pos, out, types, time);
        pos += def.length;
      } else if (header & 0x40 != 0) {
        // Definition message.
        if (pos + 5 > end) break;
        final littleEndian = b[pos + 1] == 0;
        final globalMsg =
            littleEndian ? _u16(b, pos + 2) : _u16be(b, pos + 2);
        var p = pos + 4;
        final numFields = b[p++];
        final fields = <_FieldDef>[];
        for (var i = 0; i < numFields && p + 3 <= end; i++) {
          fields.add(_FieldDef(b[p], b[p + 1], b[p + 2]));
          p += 3;
        }
        if (header & 0x20 != 0 && p < end) {
          // Developer data flag: parse developer field definitions too —
          // their sizes count toward the data message length.
          final numDev = b[p++];
          for (var i = 0; i < numDev && p + 3 <= end; i++) {
            fields.add(_FieldDef.developer(b[p], b[p + 1], b[p + 2]));
            p += 3;
          }
        }
        defs[header & 0x0F] = _MessageDef(globalMsg, fields, littleEndian);
        pos = p;
      } else {
        // Data message.
        final def = defs[header & 0x0F];
        if (def == null) break; // data without definition: corrupt
        _handleData(def, b, pos, out, types, null);
        pos += def.length;
      }
    }
  }

  void _handleData(_MessageDef def, List<int> b, int offset,
      List<TrackPoint> out, Set<int> types, DateTime? compressedTime) {
    if (offset + def.length > b.length) return; // truncated record: drop
    switch (def.globalMessage) {
      case _fileIdMessage:
        for (final f in def.fields) {
          if (f.number == _fileIdTypeField && !f.developer) {
            final v = _readInt(b, offset, def, f);
            if (v != null) types.add(v);
          }
        }
        break;
      case _recordMessage:
        _handleRecord(def, b, offset, out, compressedTime);
        break;
      default:
        break; // laps, sessions, events, device info: not needed for the map
    }
  }

  void _handleRecord(_MessageDef def, List<int> b, int offset,
      List<TrackPoint> out, DateTime? compressedTime) {
    int? latRaw;
    int? lonRaw;
    DateTime? time;
    for (final f in def.fields) {
      if (f.developer) continue;
      if (f.number == _fieldPositionLat) {
        latRaw = _readInt(b, offset, def, f);
      } else if (f.number == _fieldPositionLon) {
        lonRaw = _readInt(b, offset, def, f);
      } else if (f.number == _fieldTimestamp) {
        final raw = _readInt(b, offset, def, f);
        if (raw != null && raw != _invalidTimestamp) {
          time = DateTime.fromMillisecondsSinceEpoch(
              (_fitEpochSeconds + raw) * 1000,
              isUtc: true);
          if (raw >= 0x10000000) _refSeconds = raw; // absolute timestamp
        }
      }
    }
    time ??= compressedTime;
    if (latRaw == null || lonRaw == null) return; // pause / no fix
    if (latRaw == _invalidCoord || lonRaw == _invalidCoord) return;
    out.add(TrackPoint(
      lat: latRaw * _semicircleToDeg,
      lon: lonRaw * _semicircleToDeg,
      time: time,
    ));
  }

  /// Reads the first scalar value of an integer field (never more than the
  /// first 4 bytes). Little/big endian aware; sign-extends sint8/16/32.
  /// Returns null when the field is truncated (payload cut short).
  int? _readInt(List<int> b, int base, _MessageDef def, _FieldDef f) {
    final p = base + f.offset;
    final n = f.size > 4 ? 4 : f.size;
    if (p + n > b.length) return null;
    var value = 0;
    for (var i = 0; i < n; i++) {
      final byte = b[p + (def.littleEndian ? i : n - 1 - i)];
      value |= byte << (8 * i);
    }
    switch (f.baseType & 0x0F) {
      case 0x01: // sint8
        if (n == 1 && value & 0x80 != 0) value -= 0x100;
      case 0x03: // sint16
        if (n == 2 && value & 0x8000 != 0) value -= 0x10000;
      case 0x05: // sint32
        if (n == 4 && value & 0x80000000 != 0) value -= 0x100000000;
    }
    return value;
  }
}

int _u16(List<int> b, int o) => b[o] | (b[o + 1] << 8);
int _u16be(List<int> b, int o) => (b[o] << 8) | b[o + 1];

class _FieldDef {
  _FieldDef(this.number, this.size, this.baseType) : developer = false;
  _FieldDef.developer(this.number, this.size, this.baseType)
      : developer = true;

  final int number;
  final int size;
  final int baseType;
  final bool developer;
  int offset = 0;
}

class _MessageDef {
  _MessageDef(this.globalMessage, List<_FieldDef> fields, this.littleEndian)
      : fields = List.unmodifiable(fields) {
    var len = 0;
    for (final f in fields) {
      f.offset = len;
      len += f.size;
    }
    length = len;
  }

  final int globalMessage;
  final bool littleEndian;
  final List<_FieldDef> fields;
  late final int length;
}
