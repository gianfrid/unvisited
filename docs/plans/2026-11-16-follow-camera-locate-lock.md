# Follow-camera: locate locks, pan releases, position bottom-center, orientation from Settings only

Implements: —

## Context (current behavior)

- Follow-camera lives in `lib/ui/recording_dashboard.dart` (`RecordingDashboardState`):
  it arms on session start and on a Locate tap (`armFollow`/`rearmFollow` from
  `map_page.dart`'s `_locate`); any user gesture move releases it, and a 20 s
  timer (`reengageDelay`) auto re-engages it.
- While armed, `_onRecordingFix` frames the fix below screen center
  (`followLeadFraction`) only when a fresh heading exists, offset along the
  course — so in north-up mode the fix drifts off-center sideways.
- The recording chip carries a rotation-mode `IconButton`
  (`rotation-mode-button`) that toggles course-up and re-arms the follow.

## Requested behavior

1. Locate press activates follow; panning the map disengages it; pressing
   Locate again reactivates it. No timed auto re-engage.
2. While locked, the own position is always slightly bottom-center on screen,
   in both north-up and course-up modes.
3. Course-up orientation is activated only from Settings
   ("Rotate map while recording"); the chip button goes away.

Scope assumption: follow exists only during a recording session (no position
stream exists outside one, and background location is forbidden by SPEC), so
"locate activates follow" applies to the in-session Locate shortcut; outside a
session Locate stays a one-shot center.

## Steps

1. `lib/ui/recording_dashboard.dart`
   - Remove `reengageDelay` and `_reengageTimer`; `_releaseFollow()` only clears
     `_follow` (update the doc comments on `_follow`, the map-event listener and
     `_onModelChanged` that mention the timed re-engage).
   - In `_onRecordingFix`: always apply the `followLeadFraction` offset while
     following (drop the heading/staleness gate on the offset), directed
     opposite screen-up — geographic bearing `(360 - camera.rotation) mod 360` —
     instead of along the fix heading, so the fix sits bottom-center in screen
     space in both rotation modes. Keep the zoom floor and the rotation logic
     unchanged.
   - Remove the rotation-mode `IconButton` (key `rotation-mode-button`) and its
     comment from `_dashboard`.
2. `lib/l10n/app_strings.dart`: remove `rotationModeTooltip` (abstract getter
   plus English and Italian implementations) — no longer referenced anywhere.
3. `test/map_page_test.dart`
   - Replace "a pan releases the follow, which re-engages after the timeout"
     with: a pan releases the follow, it stays released past the old 20 s
     timeout, and a Locate tap re-arms it (the next fix re-centers).
   - Replace "the rotation-mode button cycles the setting and re-engages the
     follow" with: while recording, the chip shows no rotation-mode button.
   - Update "the follow frames the fix below screen center ...": assert the
     bottom-center offset applies without a heading and in default north-up
     mode (camera center south of the fix), plus the unchanged zoom floor.
4. Docs: verify ARCHITECTURE.md / SPEC.md do not describe the timed re-engage
   or the chip's rotation button (grep says they don't); no doc change unless
   something references them.
5. Verify: `flutter analyze` clean, `flutter test` passes; commit the plan
   file together with the change.
