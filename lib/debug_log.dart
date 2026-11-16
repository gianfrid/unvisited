/// In-app debug log: a capped ring buffer of timestamped entries, written
/// only while debug logging is enabled (Settings -> "Debug logging").
/// Exported compressed (gzip) through the Settings "Save debug log" action
/// so a session's behavior can be sent in for analysis. Pure Dart — no
/// Flutter imports — so the engine and the model can log from anywhere.
library;

class DebugLog {
  DebugLog._();

  static final DebugLog instance = DebugLog._();

  /// Ring buffer capacity; at 1 fix/s that is well over an hour of
  /// recording plus the surrounding events.
  static const int maxEntries = 5000;

  /// Master switch, mirrored from the persisted `debugLogging` setting.
  /// While false, [add] is a no-op and nothing accumulates.
  bool enabled = false;

  final List<String> _entries = [];

  void add(String level, String message) {
    if (!enabled) return;
    _entries.add('${DateTime.now().toIso8601String()} $level $message');
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  void info(String message) => add('INFO', message);

  void warn(String message) => add('WARN', message);

  void error(String message) => add('ERROR', message);

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  /// The whole buffer as plain text, one entry per line.
  String dump() => _entries.join('\n');

  void clear() => _entries.clear();
}

/// Matches a `lat,lon` decimal-degree pair as logged by the recording and
/// locate paths (e.g. `fix accepted: 51.507400,-0.127800 speed=…`).
final RegExp _latLonPair = RegExp(r'(-?\d{1,3}\.\d+),\s*(-?\d{1,3}\.\d+)');

/// Quantizes every `lat,lon` pair in [log] to 3 decimals (~111 m) so an
/// exported log can be shared for analysis without leaking exact locations.
/// Pairs are only rewritten when they parse as a valid latitude (±90) and
/// longitude (±180); anything else (speeds, ages, timestamps) is untouched.
/// Deterministic and idempotent, and it preserves local geometry — speeds,
/// heading changes and fix-quality patterns stay readable.
String anonymizeDebugLog(String log) => log.replaceAllMapped(_latLonPair, (
  m,
) {
  final lat = double.tryParse(m.group(1)!);
  final lon = double.tryParse(m.group(2)!);
  if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
    return m.group(0)!;
  }
  return '${lat.toStringAsFixed(3)},${lon.toStringAsFixed(3)}';
});
