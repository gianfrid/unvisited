Implements: —

# Playback mode: hide record/locate buttons; show "re-center on replay" only after a pan

## Current behavior

- During playback on Android the pill's last slot is still the GPS locate button; on desktop (no location plugin) it is a follow-replay button — but it is shown the whole time, armed or not.
- The record cluster (`RecordCluster`) stays visible during playback.
- While recording with the follow armed, the locate button stays visible (a near no-op).
- The locate keyboard shortcut during playback on Android does a real GPS locate.

## Desired behavior

During playback:
1. `RecordCluster` is hidden entirely.
2. The pill's last slot is empty while the follow-camera is armed on the replay cursor.
3. When a gesture releases the follow (user panned away), the slot shows a "re-center on replay" button that re-arms the follow on the playback position (`PlaybackDashboardState.rearmFollow`), not a GPS locate.
4. The locate keyboard shortcut dispatches the same re-arm while playback runs (parity with the button).

While recording (agreed extension of the same rule):
5. The last slot is empty while the session's follow-camera is armed on the current fix; it appears only when the follow is released (a pan, or no fix yet — during cold GPS the locate button stays, since it is the way to get the first fix).
6. With the follow released the button re-centers on the session's fix (`RecordingDashboardState.rearmFollow`), exactly the existing `_locate()` session branch.

Idle (no session, no playback) changes nothing: there is no follow to be locked on, and the locate button keeps its one-shot "where am I" role.

## Steps

1. `lib/ui/playback_dashboard.dart`
   - Pass `onFollowChanged` to `FollowCamera` so a follow flip (arm/release) notifies `player.playbackLive` (guarded for the unmounted window) — this is the reactive channel that rebuilds the pill on pan-release/re-arm.
   - Expose `bool get follow => _follow.follow;` on `PlaybackDashboardState`.
2. `lib/ui/recording_dashboard.dart` / `lib/ui/follow_camera.dart`
   - The recording dashboard already rebuilds on `onFollowChanged`; expose `bool get follow` on its state too if not present. No change to `FollowCamera` (hook exists).
3. `lib/ui/map_page.dart`
   - Build: when `model.playback != null`, skip mounting the record cluster (extend the existing `if (widget.locationSupported)` gate).
   - Compute `playbackFollowReleased` for the pill: `model.playback != null && !(_playbackKey.currentState?.follow ?? true)` (default armed so no button flashes at replay start).
   - Likewise `recordingFollowReleased` from `_dashboardKey` (default armed at session start; cold GPS = no fix = not armed → button shows, as desired).
   - Pass both to `MapControlPill`.
   - `_locate()`: make the playback branch platform-independent (`if (widget.model.playback != null) { _playbackKey...rearmFollow(); return; }` → currently `!widget.locationSupported && ...`).
4. `lib/ui/map_controls.dart`
   - `MapControlPill`: the last slot appears only when there is no armed follow: 
     - playback active + follow released → recenter-on-replay button (reuses `followReplayLabel`/`followReplayTooltip`), tap → `onLocate` (which dispatches to `rearmFollow`).
     - recording + follow released (or no fix yet) → locate/recenter button, tap → `onLocate` (existing session branch: recenter on fix, real locate when cold).
     - idle → locate button as today.
     - any armed follow → no slot.
   - Update the library/element doc comments to describe the new rule.
5. Localized strings: reuse the existing `followReplayLabel`/`followReplayTooltip` (they already describe re-centering on the replay); no new strings unless review shows the wording is desktop-specific.
6. Tests
   - Widget tests: during playback the record cluster is absent and the last slot is absent while follow armed; on release the recenter button appears, tapping `rearmFollow` hides it again. Recording state: button hidden while armed, visible after release / during cold GPS.
   - MapPage-level test for the shortcut dispatch if the existing tests cover `_locate` paths.

## Verification

- `flutter analyze` clean, `flutter test` green.
- Manual on desktop: start a replay → no record cluster, no last-slot button; drag the map → recenter button appears; tap → camera returns to the cursor, button vanishes. Same check while a recording session runs (Android/emulator): hidden while locked on the fix, appears after a pan, re-centers on the session fix.
