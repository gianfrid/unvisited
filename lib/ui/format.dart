/// The one distance and duration format every surface shares: the
/// recording chip, the stats panel, the tracks drawer.
library;

/// Compact distance: meters under the kilometer, then km with the last
/// digit dropped past double digits. The one format every shown distance
/// uses (the recording chip and stats panel, the tracks drawer).
String formatDistance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} km'
    : '${meters.round()} m';

/// Clock-like duration: h:mm:ss past the hour, mm:ss otherwise. The one
/// format every recording duration uses (the chip, the stats panel).
String formatDuration(Duration d) => d.inHours > 0
    ? '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
          '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}'
    : '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
          '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

/// Compact local date-time for the photo preview's caption:
/// `yyyy-MM-dd HH:mm`. Locale-independent on purpose — the app's own
/// strings are hand-rolled, and a numeric stamp reads the same in every
/// supported language.
String formatDateTime(DateTime d) {
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}
