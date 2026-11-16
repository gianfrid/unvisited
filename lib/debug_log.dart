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
