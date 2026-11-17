# Coros-style two-threshold hysteresis on the course/compass speed gate

Implements: —

## Problem

Research (`docs/navigation-follow-camera-prior-art-research-report.md` §2.3/§4.2)
shows mature products use a **two-threshold hysteresis**, not a single gate:
Coros enters compass mode below 2 km/h and leaves it only above 5 km/h;
OsmAnd ignores the GPS bearing below 0.5 m/s. Unvisited's current single gate
(`rotationSpeedGateMps = 1.0` in `lib/ui/recording_dashboard.dart`) lets the
heading source flap fix-to-fix when the speed hovers around 1 m/s — the camera
wobbles between course and compass exactly at the boundary (the "spins at a
red light" bug class).

## Plan

1. `lib/ui/recording_dashboard.dart`:
   - Replace `rotationSpeedGateMps` with `compassEnterGateMps = 0.6`
     (~2 km/h) and `compassExitGateMps = 1.4` (~5 km/h).
   - Add `bool _compassMode = false`; reset it on the session boundary in
     `_onModelChanged` alongside `_lastFixAt` / `_recentHeadings`.
   - In `_onRecordingFix`: update `_compassMode` from the fix's speed —
     enter compass mode when `speed < compassEnterGateMps`, leave it only when
     `speed > compassExitGateMps`; a fix with unknown speed keeps the current
     mode. `belowGate` becomes `_compassMode`; `effectiveHeading` uses the
     compass when in compass mode and a compass heading is available
     (unchanged fallback semantics: in compass mode with no compass reading,
     hold the rotation, still center).
   - Debug log the mode switches: `compass mode on (speed=…)` /
     `compass mode off (speed=…)`; keep the existing `compass override:` line.
   - Update the doc comments on the gate constants and `_onRecordingFix`.
2. Tests (`test/map_page_test.dart`):
   - New widget test: course at 5 m/s → drop to 0.8 m/s (between the gates)
     with a live compass at a different heading → rotation must NOT swing to
     the compass; drop below 0.6 → compass drives the rotation; rise to
     1.0 m/s → still compass (hysteresis holds); rise above 1.4 → course
     drives again.
   - Existing gate tests (speed 0.2 hold, compass at 0.2) keep passing
     unchanged: 0.2 < 0.6 enters compass mode, 5.0 > 1.4 is course mode.
3. Verify: `flutter analyze` clean, `flutter test` passes; commit the plan
   and the change together.
