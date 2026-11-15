# TODO unit 2: smooth the course-up rotation approach

Source: docs/map-rotation-research-report.md §5 item 2 — keep the 1°
hysteresis and short-arc wrap, but approach the target with exponential
smoothing per fix instead of an instant `moveAndRotate` snap. At 1 Hz
fixes, smoothing in Dart is enough; no new package.

## Change
`lib/ui/recording_dashboard.dart`, `_onRecordingFix()` rotation branch:

- Add `rotationSmoothingFactor` (k ≈ 0.4) next to the other constants.
- When the course delta clears `courseDeltaThreshold`, instead of
  snapping to `nearestEquivalentRotation(heading, rotation)`, step part
  way: `rotation + courseDelta * k` (courseDelta is already the
  short-arc delta, so the wrap handling is unchanged), and
  `moveAndRotate` to that intermediate value.
- Below the threshold (or below the speed gate): plain `move()`, as
  today.

## Tests
- Extend/add widget tests in test/map_page_test.dart: after one fix with
  a heading 90° off the camera's rotation, the camera's rotation moves
  toward 90 but not all the way in one fix (with k=0.4, ~40% of the
  delta), and converges on the next same-heading fix.
- Existing rotation tests use single fixes and assert the final
  rotation — check whether they need two same-heading fixes now to
  reach the target exactly, and adjust minimally.

## Verification
- `flutter analyze` clean, `flutter test` passes.
- Commit PLAN.md + change + tests, remove TODO.md unit in the same
  commit, detached release build per workflow step 4.
