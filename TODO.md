<!-- Open work lives here; completed items are deleted, not ticked. -->

1. Top-area vertical stack — the aggregate selection bar and the recording HUD chip both stack independently under the top toolbar and overlap it (and each other) on narrow screens.
   1. Compose toolbar + selection bar + recording chip as one non-overlapping vertical column in `MapPage`.
   2. Widget tests for the layout (selection bar visible, recording chip visible, both).

2. Remove the recording lock icon; add a persistent keep-screen-on setting — the chip's screen-lock toggle is useless; instead a Settings option (default yes) keeps the screen on during recording and applies immediately, even mid-session.
   1. Add `keepScreenOn` (default `true`) to `AppSettings`/`TrackStore`/`AppModel`.
   2. Remove the chip's `screen_lock_portrait` IconButton from `RecordingDashboard`; the latch follows the setting immediately via a model listener (not just at session start).
   3. Add the Settings UI row (Android-only, like the battery advisory) with en + it strings.
   4. Unit/widget tests for the setting, the removed icon and the immediate application.

3. Recording notification stays open after the session is stopped — `RecordingSession.start` subscribes to the position stream but nothing cancels the subscription on stop/discard, so geolocator's foreground service (and its ongoing notification) keeps running after Stop.
   1. Cancel the stream subscription in `RecordingSession.stop` (store the `StreamSubscription` from `start`), so the foreground service and its notification end with the session; covers `discardRecording` too.
   2. Unit test: after `stop`, delivered fixes are no longer processed.
   3. Manual verification on Android: the "Recording" notification is gone after Stop and after Discard.

4. Automatic release-APK build on TODO-item completion — a script that runs `flutter build apk --release --split-per-abi --target-platform=android-arm64` when a TODO.md item is completed; the agent runs it synchronously and blocks the turn until the build finishes (no new prompt mid-build). At least 5 minutes between builds, measured from the previous build's end; a completion inside the window skips (no queueing).
   1. Write the script (e.g. `tool/build_release_apk.sh`): a timestamp file records the last build's end; inside the 5-minute window it exits without building, otherwise it runs the build synchronously and updates the timestamp on completion.
   2. Wire it into the task workflow: after committing a TODO.md item, run the script and wait for it before ending the task.
   3. On build failure: log to a file, no retry loop — the next TODO-item completion after the window tries again.
   4. Verify: two TODO-item completions inside 5 minutes trigger only one build; a completion after the window triggers a new one.
