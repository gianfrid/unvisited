# Imported-track moving time

Implements: —

Imported tracks currently expose a single duration (`TrackData.durationSeconds`,
end minus start of the point timestamps), so "total" and "moving" are the same
number by construction. The recording engine already computes both
(`RecordingSession.elapsed` vs `movingTime`); this slice gives imported tracks a
real moving time using the same rule, stores it in the catalog, and shows it in
the track info dialog.

## Rule (mirrors the recorder, displacement-based)

For each pair of consecutive points that both carry timestamps:

- gap > 30 s counts nowhere — the same fix-loss threshold the recorder uses to
  close a `<trkseg>`, so a pause/segment break is "a jump, not time", matching
  the distance rule;
- otherwise the gap counts as moving iff `haversineMeters / gapSeconds >=
  movingSpeedMps` (the shared 0.5 m/s threshold);
- a missing timestamp on either side breaks the chain (the gap counts nowhere).

`movingSeconds` is null when the track has no usable timestamps, like
`durationSeconds`. Imports have no per-point sensor speed (TrackPoint stores
none), so the displacement fallback is used for every format — this is exactly
what the recorder does when the sensor speed is absent, keeping engine and
catalog numbers in agreement.

## Steps

1. `lib/geo.dart` (pure Dart, already imported by both sides): add
   `const double movingSpeedMps = 0.5;` and `const Duration segmentBreakGap =
   Duration(seconds: 30);`.
2. `lib/recording/recording_session.dart`: default `movingSpeed` and the
   fix-loss threshold reference the shared constants instead of literals.
3. `lib/models/track.dart`: add `double? get movingSeconds` to `TrackData`
   implementing the rule above.
4. `lib/storage/track_store.dart`: add nullable `movingSeconds` to `StoredTrack`
   (`toMap`/`fromMap`, tolerant of missing/malformed like the other fields), set
   it at import time next to `durationSeconds`, and heal it in `loadPoints`
   under the same self-healing rule (fill when null, never overwrite, persist
   once).
5. `lib/ui/track_list.dart` info dialog: add a "Moving time" row and compute
   the average speed over moving time when `movingSeconds > 0`, falling back to
   duration otherwise (same precedence as the recording dashboard's
   distance/moving-time average).
6. `lib/l10n/app_strings.dart`: new `infoMovingTime` string, English
   ("Moving time") and Italian ("Tempo in movimento"); register it in
   `test/app_strings_test.dart`'s pinned map so both languages are covered.

## Tests

- New `test/track_moving_time_test.dart` (pure Dart, synthetic points — no
  fixtures needed): stationary track → moving 0 while duration > 0; continuously
  moving track → moving ≈ duration; a > 30 s gap counts in duration but not in
  moving; missing timestamps → null; single-point track → null.
- Store coverage (via the existing temp-dir helpers in `test/helpers.dart`):
  import a timestamped GPX fixture → index carries `movingSeconds`; a legacy
  index entry without the field heals on `loadPoints` and is never overwritten
  once set.

## Verification

- `flutter analyze` clean, `flutter test` passes (offline default run).
- Manual (desktop): import a GPX fixture with a pause, open the track's info
  dialog, verify Moving < Duration and avg speed = distance / moving.
