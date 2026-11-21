# Control pill + playback bar polish (PR #4 review feedback)

Implements: — (follow-up to `docs/plans/2026-11-21-map-controls-rework.md`, PR #4)

Four fixes from running the desktop build and reading the playback bar render:

1. **Way back to the replay cursor on desktop.** Today the pill's locate
   button only exists where a location plugin is (Android); on desktop a
   pan during playback releases the follow with no way back. Fix: the
   pill shows a *follow* button whenever `model.playback != null` and no
   location plugin exists (desktop), icon `Icons.center_focus_strong`,
   new strings `followReplayLabel`/`followReplayTooltip` (en+it). Its tap
   re-arms the playback follow-camera on the engine's current cursor
   position: `PlaybackDashboardState` becomes public with a
   `rearmFollow()` (mirrors `RecordingDashboardState.rearmFollow`,
   reached via a `GlobalKey` in `MapPage`, called from `_locate()`'s new
   playback branch). Android behavior unchanged (GPS locate there; the
   play button already re-arms during playback).
2. **Bigger pill/cluster buttons, captions clear of the border.**
   `HeaderAction` gains optional `width` (default 48) and `iconSize`
   (default 20 — toolbar unchanged); the control pill and record cluster
   pass 56 / 24. Pill container and record-cluster Material get
   horizontal padding so captions no longer touch the rounded border.
3. **Playback bar spacing.** Card padding 4/4 → 8/6; row 1 gaps around
   the scrubber 4 → 8 and transport buttons iconSize 24 without compact
   density; row 2 name/metadata gap 8 → 12, speed chip padding 10 → 12.
4. **Tests.** New: desktop + playback → follow button appears, pan
   releases the follow, tapping it re-centers on the cursor; pill
   hidden-locate-on-idle-desktop test unchanged. Run full suite +
   analyze; verify visually via `flutter run -d linux` + screenshot.

## Verification

- `flutter analyze` clean, `flutter test` green.
- Desktop screenshot of pill + playback bar (X11 capture) reviewed.
- Amend/add commit(s) on `map-controls-rework`; PR #4 updates.
