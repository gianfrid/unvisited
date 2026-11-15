# Reject speed-outlier fixes in the recording engine (Hampel-style)

Motivation: a recorded track showed a 145 km/h max speed in OpenTracks —
one outlier fix (40.3 m jump in 1.00 s, ~40 m/s) while neighboring fixes
moved at ~3.5 m/s. The accuracy filter (≤50 m) cannot catch it: the fix's
error sat inside its own accuracy budget. Literature: Hampel filter
(sliding-window median + MAD, Pearson et al. 2016; BMDA 2023 benchmark,
ceur-ws.org/Vol-3379/BMDA_2023_paper_1870.pdf) — the median's 50% breakdown
point makes it immune to the outlier itself, unlike mean±σ.

## Changes

1. **`lib/recording/recording_session.dart`**
   - New `FixDisposition.rejectedSpeed`.
   - New knobs: `speedWindow` (default 9 — ring buffer of recent implied
     step speeds, also the minimum sample count before the MAD test runs),
     `speedMadK` (default 3.0), `maxSpeedMps` (default 45.0 ≈ 162 km/h,
     absolute backstop), `minSpeedThresholdMps` (default 12.0 — floor so
     standstill, median=MAD=0, doesn't reject legitimate acceleration).
   - In `processFix`, for non-first fixes inside a continuous segment
     (not across a segment break or resume): implied speed =
     haversine step / gap. Reject if `implied > maxSpeedMps`, or if the
     window is full and `implied > max(median + speedMadK·1.4826·MAD,
     minSpeedThresholdMps)`. Rejected fixes are never staged and never
     counted in distance/stats; accepted implied speeds feed the window.
   - Class doc: add the speed-outlier bullet to the filter list.

2. **Tests** (`test/recording_session_test.dart`, synthetic streams):
   - spike like the real recording (window at ~3.3 m/s, one 40 m/s jump)
     → `rejectedSpeed`, pointCount/distance unchanged, window unpolluted
     (next fix still accepted);
   - absolute cap: teleport with an empty window → `rejectedSpeed`;
   - floor: standstill (window of zeros) then an 11 m/s step → accepted.

3. **Docs**: ARCHITECTURE.md engine bullet and SPEC.md recording rule get
   the new filter line.

## Verification

- `flutter analyze` clean, `flutter test` passes.
- Re-run a spike analysis over the user's recording shape (synthetic) to
  confirm the outlier is dropped; commit PLAN.md + code + tests + docs.
