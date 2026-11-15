# TODO unit 2: follow-camera framing (offset below center, zoom floor)

While the follow-camera rides a fix, center the map slightly *behind*
the fix along the course (about 18% of the screen height), so the
position sits centered horizontally but below the vertical center and
more of what is ahead is visible. Also enforce a minimum follow zoom
(17) so the recording view is not too zoomed out.

## Change
`lib/ui/recording_dashboard.dart` `_onRecordingFix()`:
- Compute `zoom = max(camera.zoom, followZoomFloor)` (new const 17.0).
- Compute the camera center: when an effective heading exists, shift the
  center opposite the heading by `0.18 * screenHeight` pixels converted
  to meters at the current zoom (`156543.03 * cos(lat) / 2^zoom`); without
  a heading, center on the fix as today.
- Use that center/zoom in both the plain `move` and `moveAndRotate`.

## Tests
Widget tests in test/map_page_test.dart: while following with an east
heading, the fix's screen position is at horizontal center and below
vertical center (project the fix with the camera); zoom never drops
below the floor even if the user zoomed out.

## Verification
analyze clean, tests pass; commit PLAN.md + change + TODO removal.
