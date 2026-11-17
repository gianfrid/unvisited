# Remove the explicit compass rotation mode

Implements: —

## Goal

The recording dashboard's rotation setting offers three modes: `north`, `course`,
`compass`. The explicit `compass` mode is redundant with `course` mode's
speed-gated behavior (below `compassEnterGateMps` ≈ 2 km/h the compass already
drives the rotation; above `compassExitGateMps` ≈ 5 km/h the GPS course takes
over — hysteresis, no flapping). Collapse the setting to **North up ↔ Course up**;
the automatic low-speed compass takeover inside course mode stays as is.

Also change the chip button's icons so north-up shows a compass and course-up
shows a travel arrow:

- north: `Icons.north` → `Icons.explore` (compass rose)
- course: `Icons.trending_flat` → `Icons.navigation` (up arrow, same glyph as the
  position marker — the button echoes what the map shows)

## Steps

1. `lib/ui/app_model.dart` — `rotationModes`: `['north', 'course', 'compass']`
   → `['north', 'course']`. The chip button's cycling code is mode-count
   agnostic; with two entries it becomes a toggle.
2. `lib/storage/track_store.dart` — `_migrateMapRotation`: add
   `'compass' => 'course'` (course mode now contains the compass takeover, so
   it is the faithful successor). Update the `mapRotation` field's doc comment
   (lines ~214–215) that enumerates the modes.
3. `lib/ui/recording_dashboard.dart`:
   - `rotationModeName`: drop the `'compass'` case.
   - `rotationModeIcon`: swap icons per the pair above.
   - `_onRecordingFix`: `compassDriven = mode == 'compass' || _compassMode`
     → `_compassMode` only; update the surrounding comments that describe the
     three modes (lines ~280–320). The `_compassMode` hysteresis gates, the
     compass subscription and the smoothing stay untouched.
4. `lib/ui/settings_sheet.dart` — remove the compass `ButtonSegment` from the
   rotation `SegmentedButton`.
5. `lib/l10n/app_strings.dart` — remove `rotationModeCompass` from the abstract
   `AppStrings` class and both implementations (en, it).
6. `lib/ui/map_page.dart` — comment at line ~301 mentions
   "`mapRotation` 'course' or 'compass'": update to the two modes.
7. Tests:
   - `test/app_model_test.dart` (~lines 864–865): the `'compass'` roundtrip
     becomes a migration test — a stored `'compass'` loads as `'course'`.
   - `test/map_page_test.dart`:
     - chip cycling test (~1120–1136): update to the two-mode toggle
       (north → course → north).
     - "compass mode drives the rotation from the compass even at speed"
       (~1138+): remove — the behavior no longer exists. The existing
       low-speed-gate and hysteresis tests (course mode) stay and keep
       covering the compass takeover.
   - `test/app_strings_test.dart`: add `rotationModeNorth`/`rotationModeCourse`
     to `allStrings` (pre-existing gap — they were never listed; the coverage
     test's intent says they should be).
8. Docs:
   - `ARCHITECTURE.md` dashboard paragraph (line ~72): update the rotation
     description — two-mode setting, course mode's speed-gated compass
     takeover (the "below 1 m/s" phrasing also drifts from the actual
     0.6/1.4 m/s hysteresis gates; align it).
   - `SPEC.md` line 12 already describes the two-mode reality (north-up
     default, course-up opt-in) — no change needed.
9. `flutter analyze` (clean) + `flutter test`; commit everything (plan file
   included) in one slice.

## Out of scope

- The compass sensor plumbing itself (`flutter_compass` subscription, gates,
  smoothing) — unchanged, now used only by course mode's low-speed takeover.
- The marker glyph (`Icons.navigation` on the map) — unchanged.
