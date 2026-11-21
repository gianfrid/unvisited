# Follow-camera: a hand's zoom survives release/re-arm (pinch + Locate re-floor)

Implements: TODO.md #1

## Symptom

While recording: pinch-zoom out, pan away (the follow releases), tap
Locate (the follow re-arms) — the ride then pulls the zoom back up to the
follow floor (17), undoing the hand's zoom. The pill's +/- buttons already
survive this path: their center-static zoom-only moves are adopted into
`_rideZoom`, which `reset` clears only on a followed-thing boundary and a
plain release/re-arm keeps.

## Root cause

`lib/ui/follow_camera.dart`, map-event listener: `_rideZoom` is adopted
only for moves with `oldCamera.center == camera.center` — the pill's
buttons pass the center through unchanged, but a pinch (and the scroll
wheel) changes the center too, so the hand's zoom is never recorded. On
re-arm, the next fix targets `max(camera.zoom, followZoomFloor)` again and
walks the zoom back to the floor.

## Fix

In `FollowCamera`'s map-event listener:

1. A gesture-sourced move event (`_moveGestures`: multi-finger, fling,
   double-tap-zoom, scroll wheel) whose zoom changed adopts
   `event.camera.zoom` as the ride's zoom. The adoption runs *before* the
   `!follow` early-return and before the release branch — implemented this
   way after a test caught the naive ordering: the releasing event is the
   first gesture event the listener sees while armed, so adopting only
   while armed pinned `_rideZoom` to the first wheel notch (16.0) instead
   of the hand's final zoom (7.0). A pure pan changes no zoom and adopts
   nothing; a glide frame is never a gesture source, so no glide-write
   guard is needed on this path.
2. The center-static programmatic branch (the pill's +/− buttons) is
   unchanged; both branches share the `_adoptRideZoom` step from the
   2026-11-21 fix, which also re-targets a glide in flight onto the
   adopted zoom.
3. `_rideZoom` semantics are unchanged: cleared in `reset` (followed-thing
   boundary), kept across release/re-arm.

## Test

`test/map_page_test.dart`, next to the zoom-tap regression test: "a wheel
zoom-out survives the follow re-arm (Locate)" — start recording, settle at
17, ten scroll-wheel notches out (zoom 7, follow releases), tap Locate
(re-arm), feed a fix, and assert the camera stays at the hand's zoom (~7),
not the floor. Fails on the pre-fix code (camera re-floors to exactly
17.0); the naive "adopt only while armed" ordering fails it too (pinned at
the first notch, 16.0).

## Verification

- `flutter analyze` clean
- `flutter test` passes (444 tests)
- TODO.md #1 removed in the same commit
