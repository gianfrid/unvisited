# Anonymize gzipped debug logs

Implements: —

## Context

`lib/debug_log.dart` keeps a ring buffer of `<ISO8601> <LEVEL> <message>`
lines; Settings → "Save debug log" exports it gzip-compressed as
`unvisited-debug-<stamp>.log.gz` so a session can be sent in for analysis.
Several messages carry precise coordinates:

- `fix accepted: <lat>,<lon> speed=… heading=…` (recording_session.dart:331)
- `fix <verdict>: <lat>,<lon>` (recording_session.dart:335, raw doubles)
- `locate: fix <lat>,<lon> age=… acc=…` (app_model.dart:625)

Sharing those logs as-is leaks the user's exact locations, which conflicts
with the SPEC privacy rule (data is local only). This adds a small CLI that
scrubs coordinates from an exported `.log.gz` before it leaves the device.

## Approach

Quantize every `lat,lon` decimal-degree pair to 3 decimals (~111 m N-S).
Deterministic and idempotent, no key or per-file state, and it preserves
local geometry (speeds, heading changes, fix-quality patterns) so the log
stays useful for debugging. Pairs are only rewritten when they parse as a
valid latitude (±90) / longitude (±180), so unrelated numeric pairs in
messages are left alone.

## Changes

1. `lib/debug_log.dart` — add a pure-Dart, Flutter-free function
   `String anonymizeDebugLog(String log)` next to `DebugLog` (regex over
   `(-?\d{1,3}\.\d+),\s*(-?\d{1,3}\.\d+)`, range-checked in the callback,
   replaced by the pair quantized to 3 decimals). Same purity contract as
   the rest of the file, so it is unit-testable.
2. `tool/anonymize_debug_log.dart` — thin CLI wrapper in the style of the
   other `tool/` scripts: `dart tool/anonymize_debug_log.dart <in.log.gz>
   [out.log.gz]` (default output `<name>.anonymized.log.gz`). Reads gzip
   with `dart:io`'s `gzip` codec (stdlib only, no new package), writes
   gzip back. Plain (non-gzipped) input is also accepted by sniffing the
   `0x1f 0x8b` magic, since a log pasted into a file is a plausible input.
3. `test/debug_log_test.dart` — extend with cases: the three real log-line
   shapes above get quantized; timestamps, levels, speeds/headings and
   other numbers are untouched; out-of-range pairs (e.g. `999.1,2.0`) are
   left as-is; idempotency (anonymizing twice changes nothing); empty log.
4. No pubspec change (stdlib `dart:io` gzip only), no UI change, no new
   dependencies.

## Verification

- `flutter analyze` clean, `flutter test` passes (offline).
- Manual: gzip a sample log containing the three fix-line shapes, run
  `dart tool/anonymize_debug_log.dart` on it, `zcat` the output and confirm
  coordinates are quantized and everything else is byte-identical.
