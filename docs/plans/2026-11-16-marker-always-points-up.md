# Direction marker: pinned up when course-up is on, heading-relative otherwise (TODO.md #2)

Implements: TODO.md #2

## Problem / desired behavior

The recording direction marker (`Icons.navigation` triangle in
`map_page.dart`'s `_recordingMarkers()`) is rotated by
`course - camera.rotation`. Desired:

- **Course-up ON** (`mapRotation == 'on'`): the triangle is pinned
  screen-up (angle 0) always — even while the camera rotation is still
  easing toward the course, so it never visibly swings during transitions.
- **Course-up OFF** (north-up): the triangle keeps rotating with the
  course/heading relative to the camera — it must follow the direction of
  travel, especially while moving.

## Plan

1. `lib/ui/map_page.dart`, `_recordingMarkers()`: keep the `Transform.rotate`
   but make the angle conditional — `0` when `mapRotation == 'on'`, else the
   current `course - camera.rotation` as today.
2. Tests (`test/map_page_test.dart`):
   - existing course-up test: marker angle 0 (unchanged expectation).
   - existing north-up tests: marker still rotates along the course
     (unchanged expectations).
   - new discriminating case: rotation ON but camera not yet converged
     (first fix, camera at ~36°): marker angle must be 0 (pinned), not
     course − rotation.
3. Verify: `flutter analyze` clean, `flutter test` passes; commit the plan,
   the change, and remove TODO.md #2 in the same commit.
