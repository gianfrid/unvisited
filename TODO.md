<!-- Open work lives here; completed items are deleted, not ticked. -->

1. Fixed-north map orientation (default) with opt-in rotation setting — orientation is too buggy, so the map stays north-up by default (even during recording); a Settings toggle (off by default) enables the course-up follow-camera rotation. Dynamic rotation is backlog; document the fixed-north limitation in README.md, ARCHITECTURE.md and SPEC.md.
   1. Add `mapRotation` (`'off'`/`'on'`, default `'off'`) to `AppSettings`/`TrackStore`/`AppModel`.
   2. Gate the course-up camera rotation in `RecordingDashboard._onRecordingFix` on the setting.
   3. Add the Settings UI row for the rotation toggle, with en + it strings.
   4. Document the fixed-north limitation in README.md, ARCHITECTURE.md and SPEC.md.
   5. Unit/widget tests for the setting, the gated rotation and the docs.

2. Top-area vertical stack — the aggregate selection bar and the recording HUD chip both stack independently under the top toolbar and overlap it (and each other) on narrow screens.
   1. Compose toolbar + selection bar + recording chip as one non-overlapping vertical column in `MapPage`.
   2. Widget tests for the layout (selection bar visible, recording chip visible, both).

3. Remove the recording lock icon; add a persistent keep-screen-on setting — the chip's screen-lock toggle is useless; instead a Settings option (default yes) keeps the screen on during recording and applies immediately, even mid-session.
   1. Add `keepScreenOn` (default `true`) to `AppSettings`/`TrackStore`/`AppModel`.
   2. Remove the chip's `screen_lock_portrait` IconButton from `RecordingDashboard`; the latch follows the setting immediately via a model listener (not just at session start).
   3. Add the Settings UI row (Android-only, like the battery advisory) with en + it strings.
   4. Unit/widget tests for the setting, the removed icon and the immediate application.
