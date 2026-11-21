# Course-up activation re-arms a released follow

Implements: — (follow-up on PR #4)

When a recording or replay runs but the follow-camera was released (the
user panned away), tapping the pill's rotation button to *course* should
also re-arm the follow — re-center on the session fix / replay cursor —
like the locate/follow button does. Switching to north stays a pure mode
change (and idle taps still just set north, per
`2026-11-21-rotation-button.md`).

Change: `MapControlPill` gets an optional `rearmFollow` callback; the
following-branch of the rotation button calls it after toggling when the
new mode is 'course' (harmless when already armed — it re-centers on the
current fix/cursor). `MapPage` supplies it: recording →
`RecordingDashboardState.rearmFollow()`, else playback →
`PlaybackDashboardState.rearmFollow()`.

Tests: playback — pan releases the follow, tap rotation button → mode
'course', camera re-centers on the marker and rotates to course; recording
— same via the session fix (mirror of the existing locate-rearm test).
Verify: analyze, full suite, commit on `map-controls-rework` (PR #4).
