# Fix the inverted course-up camera rotation; log the follow-release source

Implements: —

## Problem (from the 2026-11-17 ride debug log + GPX)

Ride data: `/tmp/ride/unvisited-debug-2026-11-17T09-00-19.log.gz`,
`5ed5c0693265aa17.gpx` (app recording), `Bike_2026-11-17T08_13_53_01_00.gpx`
(Garmin). The logged GPS headings match the actual movement bearings computed
from the app GPX within ~±10 deg, so the heading data is good. The camera
orientation is wrong because of a sign error, and the follow-camera released
mid-ride on gesture events with no log of which gesture.

1. **Rotation sign inverted.** flutter_map 8 wraps the map in
   `Transform.rotate(angle: camera.rotationRad)` (positive = clockwise on
   screen), so a geographic bearing θ appears at screen bearing θ + rotation.
   Course-up therefore needs `rotation = −heading`. `recording_dashboard.dart`
   instead rotates toward `+mean(heading)` — log evidence:
   `fix accepted: … heading=149` → `rotate: target=149.0` (should be −149).
   At heading 149 the course lands at screen bearing 298 deg, so the
   screen-up-pinned triangle points away from the movement. The same sign
   error is in the north-up marker angle in `map_page.dart`
   (`course − rotation` should be `course + rotation`; only visible when the
   user has two-finger-rotated with course-up off). The follow-lead offset
   (`360 − rotation` as screen-up) already uses the correct convention.
2. **Follow releases on any non-programmatic map event, including taps.**
   Log shows `follow released by gesture` at 08:16:39, 08:17:06, 08:22:05,
   08:41:08, re-armed only via the locate button at 08:16:47, 08:20:29,
   08:22:07 — a 3.4 min gap (08:17:06→08:20:29) with no centering, so the
   marker rode off-screen ("disappeared after a few minutes"). A stray tap
   (mount/pocket/glove) silently kills the follow; the log does not record
   which event source caused the release.

## Plan

1. `lib/ui/recording_dashboard.dart`, `_onRecordingFix`: negate the circular
   mean before rotating — target = `−atan2(sinSum, cosSum)` (i.e. rotate toward
   the equivalent of `360 − mean`). `nearestEquivalentRotation` keeps the
   short-arc behavior across 0/360 unchanged. Update the `rotate:` debug line
   to also log the raw heading mean for comparison.
2. `lib/ui/map_page.dart`, `_recordingMarkers`: north-up marker angle becomes
   `(course + camera.rotation)`.
3. `lib/ui/recording_dashboard.dart`, follow-release listener: only release on
   *move* gestures (dragStart/onDrag/dragEnd, multiFinger*, flingAnimationController,
   doubleTapZoomAnimationController); taps/longPress no longer release. Log the
   releasing source: `follow released by gesture (source=…)`.
4. Expand debug logging: in `_releaseFollow` include `event.source`; in
   `_onRecordingFix` log when the compass overrides a below-gate heading
   (`compass heading=… used below speed gate`) and the effective heading.
5. Tests (`test/map_page_test.dart`): flip the sign expectations (heading 90
   converges camera rotation to −90/270; the lead-offset center at rotation
   −90 sits east of the fix; north-up marker angle = course + rotation), add a
   tap-does-not-release-follow case, keep the pan-releases cases.
6. Verify: `flutter analyze` clean, `flutter test` passes; commit plan +
   change + tests in one commit.
