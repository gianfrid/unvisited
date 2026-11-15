# TODO unit 1: speed-gate the course-up rotation

Source: docs/map-rotation-research-report.md §5 item 1 — apply rotation
only when ground speed is above ~1 m/s; below the gate, hold the last
rotation (kills standstill spin / low-speed jitter).

## Change
`lib/ui/recording_dashboard.dart`, `_onRecordingFix()` (the
`mapRotation == 'on'` branch):

- Add a constant, e.g. `rotationSpeedGateMps = 1.0` next to
  `courseDeltaThreshold`.
- When rotating, also require the session's ground speed to clear the
  gate: `session.currentSpeed` is already fused (reported fix speed,
  else haversine between fixes — recording_session.dart:215). If speed
  is null (source reports none, first fix), keep today's behavior and
  rotate — the gate only bites when we *know* we are slow.
- Below the gate: plain `move()` (center follows the fix, rotation is
  held — same as the sub-hysteresis path today).

No model/store changes; the setting stays opt-in as-is.

## Tests
- Widget test in test/map_page_test.dart (recording camera group, next to
  the existing rotation assertions ~line 684): a fix with
  `speed: 0.2` and a heading leaves `camera().rotation` unchanged while
  still centering; a following fix with `speed: 3.0` rotates as before.
- Keep all existing rotation tests green (they use speed 3.0 fixes).

## Verification
- `flutter analyze` clean, `flutter test` passes.
- Commit PLAN.md + change + tests together, remove TODO.md unit 1 in
  the same commit, then detached release build per workflow step 4.
