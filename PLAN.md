# PLAN — Course-up camera rotation while recording

TODO unit: "Recording — map controls & camera", item 1.

Goal: while a recording session runs with the follow-camera armed, the map
camera rotates so the current course points up — where the user is going is
shown before them. Rotation is tied to the follow-camera (owner answer): any
user gesture releases rotation together with the follow; re-arming via the
locate button lands with TODO unit 2. Still plain 2D — no tilt (backlog).

## Facts established by reading the code (flutter_map 8.3.2, app sources)

- `MapController.moveAndRotate(center, zoom, degree)` exists and is composed
  of `moveRaw` + `rotateRaw`; both emitted events carry
  `MapEventSource.mapController`, already listed in `_programmaticEvents`
  (lib/ui/map_page.dart) — the follow never releases itself.
- `move()` and `fitCamera()` only change center/zoom and preserve
  `camera.rotation`, so the zoom slider and camera fits keep the rotation.
- Two-finger rotate is part of `InteractiveFlag.all`; its events carry gesture
  sources, so the existing release branch in the map-event listener
  (`_followRecording = false` on any non-programmatic source) releases
  rotation together with the follow — no extra release code needed.
- `RecordingSession.currentCourse` is degrees clockwise from north in
  [0, 360) (device heading wins, else the per-fix bearing, both normalized);
  null until a heading or a second accepted fix exists.
- `MapCamera.rotation` is degrees, 0 = north.

## Implementation steps

1. `lib/ui/map_page.dart` — add a top-level pure helper
   `nearestEquivalentRotation(double course, double currentRotation)` that
   returns the angle equivalent to `course` mod 360 closest to
   `currentRotation`, so crossing the 0/360 boundary never spins the map the
   long way around.
2. `lib/ui/map_page.dart`, `_onModelChanged` — in the follow branch, when
   `session.currentCourse != null`, call
   `_mapController.moveAndRotate(LatLng(lat, lon), zoom,
   nearestEquivalentRotation(course, _mapController.camera.rotation))`;
   keep the plain `move(...)` when the course is not yet known.
3. `lib/ui/map_page.dart`, `_recordingMarkers` — rotate the marker by
   `(course ?? 0) - _mapController.camera.rotation` instead of `course`
   alone, so the nose points along the course on screen at any camera
   rotation (angle 0 = up while the follow has the camera on the course).
   Update the doc comment.
4. Tests in `test/map_page_test.dart`:
   - plain unit tests for `nearestEquivalentRotation` (0/360 wrap-around
     cases, already-normalized input);
   - widget test: record with `fakeFix(..., heading: 90)` → while following,
     `MapController.of(...).camera.rotation` is ~90; a drag pan releases the
     follow and the next fix leaves the rotation untouched; the marker is
     still rendered;
   - widget test: two fixes without heading moving east → course 90 via the
     bearing fallback → rotation ~90;
   - marker angle: while camera rotation == course, the marker's
     `Transform.rotate` angle is ~0.
5. Docs — ARCHITECTURE.md dashboard bullet: "course-up marker over a
   north-up camera" becomes camera rotates to the course while following,
   marker counter-rotates by the camera rotation. SPEC.md scope item 6:
   adjust the "course-up marker" wording the same way (still 2D). Remove
   TODO unit 1 from TODO.md in the same commit.
6. Verify: `flutter analyze` clean, `flutter test` green. Manual check on
   Android: record and watch the map rotate to the heading; pan or
   two-finger rotate by hand → rotation stops following.

## Out of scope for this slice

- Locate re-arming the follow while recording (unit 2), the bottom-left
  button stack (unit 3), the pause/resume/stop flow (unit 4).
- Tilt/pitch (backlog, owner decision 2026-11-13).
- No new user-visible strings, so no `app_strings.dart` changes.
