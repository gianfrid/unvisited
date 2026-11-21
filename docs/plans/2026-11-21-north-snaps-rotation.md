# North tap always snaps the camera to rotation 0

Implements: — (follow-up to `docs/plans/2026-11-21-course-activation-rearms.md`, PR #4)

Bug: with a recording/replay running and the follow released by a pan, in
course mode the rotation button toggles to north and nothing visible
happens — the mode changed, but the released follow never touches the
camera, so the map keeps its course-up rotation until the user re-arms.

Fix: make "north" mean what it says. In `MapControlPill`'s rotation tap,
the following-branch becomes:

- next == 'course': `setMapRotation('course')` + `onRearmFollow()` (as now);
- next == 'north': `setMapRotation('north')` + snap the camera to rotation
  0 with `moveAndRotate(camera.center, camera.zoom, 0.0)`.

The idle branch already does exactly the north snap, so both paths share
the same rule: north-orients-now, course-re-arms-and-follows. Because
`moveAndRotate` is a programmatic event it does not release an armed
follow, and the dashboards feed 0.0 in north mode, so an armed follow
stays north-up afterwards (no fight between the snap and the next fix).

Tests: extend the playback and recording "course-up activation re-arms"
tests — after the north tap in the released state, assert the camera
rotation snaps to ~0 while the center stays where the pan left it.
Verify: analyze, full suite, commit on `map-controls-rework` (PR #4).
