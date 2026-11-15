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

4. Automatic release-APK build on task completion — a script that runs `flutter build apk --release --split-per-abi --target-platform=android-arm64` in the background when a task is completed, blocks a new prompt until the build finishes, and enforces at least 5 minutes between builds.
   1. Write the script (e.g. `tool/build_release_apk.sh`): no-op when a build finished less than 5 minutes ago (timestamp file), otherwise launch the build in the background with a lock file so concurrent invocations don't overlap.
   2. Define the "block a new prompt" mechanism (the agent waits on the lock/background process before ending a task) and wire it into the task workflow.
   3. Verify: two consecutive task completions within 5 minutes trigger only one build; a build older than 5 minutes triggers a new one.
