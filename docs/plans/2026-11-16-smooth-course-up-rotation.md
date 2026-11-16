# Smooth the course-up camera rotation (TODO.md #1)

Implements: TODO.md #1

## Problem

The course-up rotation is laggy/choppy: each 1 Hz fix eases the camera only
`rotationSmoothingFactor` (0.4) toward the *raw* reported heading, so GPS
heading noise steps the camera fix by fix.

## Plan

1. `lib/ui/recording_dashboard.dart`, `RecordingDashboardState._onRecordingFix`:
   - Keep the per-fix easing and the 1 deg hysteresis, but smooth the
     *target*: keep a short ring of the last `_headingSmoothingWindow` (5)
     usable effective headings and rotate toward their circular mean
     (`atan2` of summed sin/cos — wrap-safe across 0/360, unlike a linear
     mean).
   - Push into the window only when the heading is actually used for
     rotation (not stale, above the speed gate or compass-backed); reset
     the window on the session boundary alongside `_lastFixAt`.
   - Constant-heading behavior is unchanged (mean of constants is the
     constant), so the existing rotation widget tests keep passing.
2. Tests (`test/map_page_test.dart`): add a noisy-heading case — headings
   alternating 80/100 deg around a 90 deg course must converge to ~90 and
   never step beyond the noise band mid-sequence (assert the per-fix
   rotation delta stays well under the raw heading delta), while a constant
   90 deg course still converges to 90.
3. Verify: `flutter analyze` clean, `flutter test` passes; commit the plan,
   the change, and remove TODO.md #1 in the same commit.
