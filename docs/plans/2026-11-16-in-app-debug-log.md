# In-app debug log: ring buffer, settings toggle, save-to-file export

Implements: —

## Diagnosis note (the flaky trace test)

The `live recording trace` widget test failed twice in ~28 full-suite runs,
always under load, never in isolation (8/8 clean single runs, 10/10 clean
full runs since). Its wall-clock math is deterministic (both fake fixes are
evaluated against a single `DateTime.now()` and sit 1 s apart, so they
always share a 30 s fade bucket; their age is days, past the fade window),
so the failure mode is frame-scheduling lag, not logic. No code change;
the debug log below is the tool to capture such issues on a real device.

## Plan

1. `lib/debug_log.dart` (pure Dart, no Flutter): a `DebugLog` singleton —
   enabled flag, capped ring buffer (last 5000 entries: ISO timestamp, level,
   message), `add(level, message)`, `dump()` to text. No-op when disabled.
2. Instrument the key paths (minimal, decision-level only):
   - `AppModel.locate`: outcome, failure reason, fix age vs freshFixMaxAge.
   - `RecordingSession` fix processing: accepted/dropped per fix with the
     reason (accuracy, Hampel speed outlier, stale, pause/segment break).
   - `RecordingDashboardState`: follow arm/release, rotation target vs
     applied, heading source (GPS/compass/held).
   - Import coordinator: start/finish with counts.
3. Settings (`settings_sheet.dart` + `TrackStore` AppSettings + `AppModel`):
   a "Debug logging" switch persisted in `index.json` (default off), new
   strings in en + it (pinned in `app_strings_test.dart`'s `allStrings`).
   When on, a "Save debug log" action writes `dump()` via
   `FilePicker.platform.saveFile` (SAF create-document on Android, native
   dialog on desktop — `file_picker` is already an established dependency)
   to `unvisited-debug-<timestamp>.log.gz`, gzip-compressed with the
   already-bundled `archive` package (`gzip.encode`) — no APK size increase,
   and log text typically compresses 5-10x. Toast on success/cancel.
4. Tests: `test/debug_log_test.dart` (cap, dump format, disabled no-op);
   settings toggle persists; strings parity. No network, no new packages.
5. Verify: `flutter analyze` clean, `flutter test` passes; commit plan +
   change together.
