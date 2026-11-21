# Rotation button: idle = set north; north mode actually rotates to north

Implements: — (follow-up on PR #4)

Two fixes:

1. **Idle tap sets north instead of toggling.** In `MapControlPill`'s
   rotation button: when a follow-camera is active (`model.isRecording ||
   model.playback != null`) the tap keeps toggling north↔course (course-up
   is meaningful there); when idle it calls `setMapRotation('north')` and
   snaps the camera to rotation 0 via `moveAndRotate(center, zoom, 0)` —
   so the button visibly orients north even after a manual two-finger
   rotate, instead of appearing dead.
2. **North mode rotates to 0 during a follow.** Root cause of "not
   actually orienting towards north": both dashboards pass `heading: null`
   in north mode and `FollowCamera.update` holds the current rotation on
   null. Fix: pass `0.0` in north mode (recording_dashboard's fix handler
   and playback_dashboard's `_onPlaybackTick`) — the existing smoothing
   window then glides the rotation to 0 (target = -0). `null` stays for
   stale/compass-less headings in course mode (hold). The 5-entry heading
   window naturally flushes on a mode switch, so course→north→course
   transitions glide smoothly; no extra clearing needed.

Tests: existing toggle test (runs during recording) unchanged; new idle
test — set 'course', rotate camera 90°, tap pill button → mode 'north'
and camera rotation 0; new playback test — course-up replay rotated to
course, tap pill button → mode 'north', after ticks camera rotation ≈ 0.
Verify: analyze, full test suite, commit on `map-controls-rework` (PR #4).
