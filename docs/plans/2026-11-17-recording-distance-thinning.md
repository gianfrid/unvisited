Implements: —

# Distance-based thinning for live recording

## Problem

`RecordingSession.acceptFix()` stages every accepted 1 Hz fix. A real ride
(`docs` analysis of /tmp/ride, 2026-11-17) produced 1518 points over 25.3 min
vs the same track on a Garmin Instinct 1 at 338 points — with no measurable
benefit: median deviation of the 1 Hz points from the Garmin line is 3.9 m
(GPS noise scale), and downsampling the app's own log to 4 s changes distance
by 0.3%. Cost: ~4× GPX size and fog-cell/road-matching work at import.

## Decision (from discussion)

Thin **while recording, at acceptance time** — not post-processing at save:

- The staged GPX is the durable, crash-salvageable artifact; thinning at the
  source keeps crash-recovered and clean-stopped files in one shape.
- The rule is local (no look-ahead needed), so seeing the whole track buys
  nothing.
- Stats (distance, moving time, speed, outlier filter) keep consuming every
  raw fix; thinning governs only what is staged.

**Rule**: stage a fix when `haversine(lastRecorded, fix) ≥ 12 m` **or**
`fix.time − lastRecordedTime ≥ 5 s`. A distance threshold is implicitly
speed-adaptive in time (`gap ≈ 12 m / speed`) and bounds the spatial step
(threshold + one sensor step), keeping the fog corridor continuous: unlock
circles are r = 15 m, so steps must stay < 30 m — 12 m + 1 s at road-bike
speed (11 m/s) = 23 m, vs 44 m for a fixed 4 s rule, which would split the
corridor.

## Changes

### `lib/recording/recording_session.dart`

1. New constructor params (defaults): `recordDistanceMeters = 12`,
   `recordMaxAge = Duration(seconds: 5)`. Doc comments state the relation to
   the fog unlock radius (15 m circles; corridor continuity needs
   `recordDistanceMeters + one sensor step < 2 × unlockRadius`) without
   importing from `lib/ui/fog_of_war.dart`.
2. New state: `_lastRecordedLat/Lon/Time` (null until the first staged fix).
3. In `acceptFix()`, after the existing filters, replace the unconditional
   `stage.appendPoint(...)` with:
   - First fix of the session → stage immediately.
   - First fix after a segment break or resume → stage immediately
     (segment endpoints anchor the corridor).
   - Otherwise stage when the displacement-from-last-recorded or max-age
     condition holds.
   - On `breakSegment` (pause or fix loss): before `stage.breakSegment()`,
     if the last accepted fix was not staged, stage it — segments end
     exactly at their last raw fix, never mid-jump.
4. `_points` (→ `pointCount`) now counts **staged** points. Nothing in the
   UI reads the session's `pointCount` (verified: only `StoredTrack.pointCount`
   from the finalized file is displayed, which stays consistent by
   construction). Distance/elapsed/moving/speed logic is untouched — all
   raw-fix based, as today.

### `test/recording_session_test.dart`

1. Straight synthetic ride (1 Hz, ~4.5 m/s): staged point count ≈ raw/3,
   `distanceMeters` identical to the unthinned expectation.
2. Stationary session: a point every ~`recordMaxAge`, no distance accrued.
3. Segment break mid-threshold: the segment's final staged point equals the
   last raw fix before the break; the post-resume first fix is staged.
4. Fast ride (11 m/s): max spatial step between staged points < 30 m
   (corridor continuity invariant) — the case where fixed-time thinning
   fails.
5. `salvageGpx` round-trip on a thinned file: re-imports through
   `TrackImporter` like any GPX (existing invariant, now over thinned
   output).

## Out of scope

- Import-side thinning (imported third-party tracks are never rewritten).
- Douglas-Peucker or turn-triggered capture (Garmin-style smart recording) —
  the turn trigger does not bound the spatial step and adds a second rule;
  the distance rule alone meets the corridor invariant.
- Any change to the export path or the unified import pipeline.

## Verification

`flutter analyze` clean; `flutter test` green; commit the slice with this
plan file.
