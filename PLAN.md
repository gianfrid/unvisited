# TODO batch: remaining map-rotation units (2–5 of the rotation item)

Implemented in one pass per user instruction (no per-item confirmation).

1. Release-on-pan with timed re-engage: a user gesture (pan or two-finger
   rotation, any non-programmatic map event) releases the follow and a
   20 s timer re-arms it; locate/mode button re-arm immediately.
2. Two-finger rotation is covered by the same release path (it reports a
   non-programmatic source), suppressing auto-rotation until re-engage.
3. Rotation-mode indicator: compass IconButton on the HUD chip; shows
   on/off, cycles the `mapRotation` setting, and re-engages the follow.
4. GPS-loss hold: a fix > 10 s after the previous one never rotates.
5. Compass below the speed gate: `flutter_compass` (added dep, user
   authorized) subscribed only while recording with rotation on; below
   1 m/s the compass heading drives rotation instead of the stale course.

## Verification
- `flutter analyze` clean, `flutter test`: 306 pass (3 new widget tests:
  timed re-engage, compass-below-gate, mode button).
