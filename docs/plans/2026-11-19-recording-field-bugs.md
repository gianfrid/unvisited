# Fix the recording field bugs (marker course, standstill heading, glide snaps)

Implements: TODO.md #1, #2, #3 (entries to be added with unit 1's commit; each entry is
removed by the commit that completes it). Entry #4 (elevation geoid) is tracked for a
future decision and is explicitly out of scope here.

## Evidence (field session 2026-11-19, phone build vs Garmin Instinct 3)

Collected from the two debug-log exports, the unvisited and Garmin GPX files, and
pixel-level analysis of the 4.78 s screen recording. No coordinates are recorded in
this file; all figures below are aggregates or screen-space bearings.

- **Marker points away from the course.** In the recording, the walked trace departs
  the marker at screen bearing 175–191° (median 180°) — i.e. the on-screen course is
  straight up, which pins the camera content rotation at the logged glide target
  (−140.5°, GPS course ≈ 137°, predicted trace bearing 179.5°, measured 180°). The
  marker's icon nose (glyph geometry: isoceles apex 45°, side ratio 1.21 = the
  `Icons.navigation` glyph) points at 229–243° across frames — ~120–135° away from
  the visible course.
- **Root cause:** `map_page.dart` builds the marker with
  `Transform.rotate(course + _markerRotation.value)`. But flutter_map 8.3.2 renders
  `MarkerLayer` children inside `MobileLayerTransformer`
  (flutter_map `marker_layer.dart:101`, which applies
  `Transform.rotate(angle: camera.rotationRad)`), so marker children ride the map's
  content rotation. The app's own `+rotation` term is counted twice: on-screen nose
  = `course + 2 × camera.rotation` ≈ 137 + 2×(−140.5) ≈ 217°, matching the measured
  229–243° within heading noise. The alternative single-rotation prediction (≈356°,
  straight up) is excluded by the measurement. Invisible in north-up mode
  (rotation 0), which is why it survived the Nov 17 marker rework.
- **Standstill heading garbage pollutes the rotation window.** geolocator reports
  `heading = 0.0` (not null) on standstill fixes — 24 consecutive such fixes during
  a 24 s stop, plus the session's first fix. The dashboard treats non-null 0.0 as a
  usable heading and pushes it into `_recentHeadings` (window 5). Proof at movement
  onset: `<18:48:01> fix speed=1.0 heading=236` produced
  `glide target: mean=-61.8` — exactly the circular mean of `[0, 236]` instead of
  the correct −124 — so the camera sat ~62° off course for the first seconds after
  the stop.
- **Camera "lag" is a per-frame snap bug.** The screen recording's motion profile:
  a smooth ~0.9 s eased glide on some fixes, but single-frame ~3 px jumps on others
  (t≈1.84 s, t≈2.84 s) followed by ~0.9 s freezes. `_setGlideTarget`
  (`recording_dashboard.dart`) resets `_prevGlideElapsed = Duration.zero` even when
  it reuses an already-running ticker (the `??=` only guards creation). The next
  `_glideTick` then computes `dt = elapsed − Duration.zero` = the ticker's whole
  age, so `k = 1 − exp(−dt/350ms)` reaches ≈0.96 and the camera jumps ~96% of the
  remaining distance in one frame. Fixes arriving while the previous glide has
  settled get a fresh ticker (smooth); fixes arriving mid-glide snap — alternating
  exactly as observed.

Not bugs (facts of the two receivers, no fix planned): the ~47 m elevation offset
(geolocator's raw height vs the watch's barometric MSL — TODO.md #4), the +35.7 m
distance difference (fully explained by the watch's 35 s later start), median lateral
track agreement 4.5 m (p90 10.6, max 23.5), and the GPS heading sensor itself
(median heading-vs-course error +0.3° over 818 accepted fixes).

Anomalies explained (no action needed): the missing `compass mode on` lines at the
session's first fix (the first accepted fix sets no fused speed — `processFix` only
sets `_currentSpeed` when `!first` — so the dashboard's speed gate is skipped), and
at the 24 s standstill (the follow was released right after the clip: glide lines
end at 18:54:39, so `_onRecordingFix` early-returns).

## Unit 1 — Marker: one rotation, not two

**Implements: TODO.md #1.** Files: `lib/ui/map_page.dart`, `lib/ui/recording_dashboard.dart`, `test/map_page_test.dart`.

1. `map_page.dart` `_recordingMarkers()`: the marker child's angle becomes
   `(session.currentCourse ?? 0) * math.pi / 180` — the camera rotation is supplied
   by the map's content transform (`MobileLayerTransformer` wraps `MarkerLayer` in
   flutter_map 8.3.2), so the app must not add it. Rewrite the surrounding doc
   comment: the nose follows the course on screen *because the layer rotates with
   the camera*; the old invariant ("angle = course + rotation") was off by the
   rotation twice.
2. Remove the now-dead publish machinery: `MapPage._markerRotation` (field,
   `dispose`, the `Listenable.merge` entry, the `markerRotation:` constructor arg),
   and in `recording_dashboard.dart` the `markerRotation` field/param and
   `_publishRotation()` with its three call sites. Grep confirms no other users.
3. Tests, `test/map_page_test.dart` (they pin the *widget* angle, which is the
   content-space angle):
   - Update `'course-up …: the marker shows the course on screen while the camera
     is still easing'` (≈line 1160): mid-glide assert `markerAngle() == 90°`
     (course only), independent of `camera().rotation`; settled: camera ≈ −90°,
     marker angle still 90° (the *screen* nose nets to up — state that in words).
   - Update `'the bearing fallback keeps the camera north-up, marker rotating'`
     (≈line 1254) and any other `recording-marker-rotate` assertion (≈lines 3353,
     and the north-up case at ≈line 1140 where the value already equals the
     course) to the course-only expectation.
   - Keep the camera-center/rotation assertions unchanged; only the marker-angle
     expectations change.
4. Commit (plan file + TODO entry #1 included; entry removed here as completed):
   `Recording marker: ride the layer's content rotation instead of adding camera rotation twice`.

## Unit 2 — Standstill fixes must not report a heading

**Implements: TODO.md #2.** Files: `lib/recording/recording_session.dart`, `test/recording_session_test.dart`, `SPEC.md`, possibly `test/map_page_test.dart`.

1. `processFix` in `recording_session.dart`: a fix whose fused speed is below
   `movingSpeed` (0.5 m/s) does not update the course at all — `_currentHeading`
   becomes null (not 0) and `_currentCourse` *holds its previous value* (no heading
   update, no bridged-bearing update; two nearly-identical positions would sling a
   noise bearing). A fix with unknown fused speed keeps today's behavior (the
   heading/bridging logic assumes the source cannot say). The standstill freeze of
   the dashboard follows automatically: `currentHeading == null` → `effectiveHeading
   == null` → the glide keeps the rotation and `_recentHeadings` is not polluted —
   which also removes the `mean` from `[0, 236]` class of misrotation at movement
   onset, including the session's very first fix.
2. Doc comment on `currentCourse`/`currentHeading` getters: extend with the
   standstill-hold rule; note that `heading = 0.0` at standstill is Android's
   "unknown" sentinel, not a real bearing.
3. `test/recording_session_test.dart`:
   - standstill fix (speed < 0.5, heading 0) after a moving fix: `currentHeading` is
     null, `currentCourse` unchanged;
   - moving fix with heading: both set (regression guard);
   - fix with `speed: null` and a heading: heading still used (legacy behavior);
   - first fix at standstill: course stays null until movement.
4. Audit `fakeFix` uses in `test/map_page_test.dart` for fixtures that pass
   `heading:` together with (near-)zero displacement: with the fused speed derived
   from displacement/time they now fall under the standstill gate — give them an
   explicit `speed:` if the test means to be moving.
5. SPEC.md, Recording invariants: add one line — a standstill fix (fused speed below
   the moving threshold) reports no heading and holds the last known course.
6. Commit (TODO entry #2 removed as completed):
   `Recording: hold the course at standstill; geolocator's heading=0.0 is "unknown", not north`.

## Unit 3 — Follow-camera: fix the glide dt reset (no mid-glide snaps)

**Implements: TODO.md #3.** Files: `lib/ui/recording_dashboard.dart`, `test/map_page_test.dart`.

1. `_setGlideTarget`: reset `_prevGlideElapsed` only when a new ticker is created
   (i.e. inside the `_glideTicker == null` branch). A reused running ticker keeps
   its monotonic elapsed → the next tick's `dt` is one frame, not the ticker's age.
   (Reset also stays in `_stopGlide`, where the ticker is disposed.)
2. Defensive clamp in `_glideTick`: `k = 1 − exp(−min(dtMs, 100) / τ)`, so no single
   frame ever advances more than ~25% of the remaining distance — cheap insurance
   against dropped-frame jank (the screen recording runs at ~24 effective fps).
3. Test in `test/map_page_test.dart`, extending the follow-camera harness
   (`FakePositionSource` + `pumpGlide`): start a follow glide on a fix, pump two
   frames (mid-ease, not settled), deliver a second fix, `await tester.pump(16 ms)`
   and assert the camera stepped only a small fraction of the remaining distance
   (red on the current code: ~96% jump; green after the fix). Assert the settle
   still converges (target reached after `pumpGlide`).
4. Commit (TODO entry #3 removed as completed):
   `Follow-camera: a reused glide ticker keeps its clock; no one-frame snaps between fixes`.

## Out of scope (tracked, not in this plan)

- TODO.md #4: elevation — decide and document the geoid-vs-MSL handling for recorded
  and imported tracks (the recorded GPX is ~47 m above the calibrated watch in this
  region; a proper fix needs an offline geoid model or an explicit "raw GPS
  altitude" caveat). To be planned separately when a decision is made.
- No change to the 1 Hz fix rate, glide τ (350 ms), or the compass-mode gates
  (`compassEnterGateMps` 0.6 / exit 1.4): the measured smooth glides are fine once
  unit 3 removes the snaps; re-tune only if the field still complains.

## Verification per unit

`flutter analyze` clean + `flutter test` green; each unit committed separately with
its plan/TODO bookkeeping. Field re-check for units 1–3 together afterwards (a short
recorded walk): marker stays on the walked line's direction on screen (nose opposite
the trace), camera holds ~no rotation error at movement onset, no visible snap on
consecutive fixes.
