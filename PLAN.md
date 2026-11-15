# PLAN: TODO.md items 1–3 — top-area column, keep-screen-on setting, stop cancels the position subscription

Three slices, each committed separately with its TODO.md entry removed in
the same commit. After each slice's commit, `tool/build_release_apk.sh`
runs detached (the script's own 5-minute window makes repeat runs skip).
No new packages; the Android host channel already maps `keepScreenOn`.

## Slice 1 — Top-area vertical stack (TODO item 1)

Files: `lib/ui/map_page.dart`, `lib/ui/map_actions.dart`,
`lib/ui/recording_dashboard.dart`, `test/map_page_test.dart`

1. `map_page.dart`: replace the three independent top `Positioned`
   overlays (`TopToolbar`, `SelectionBar`, the dashboard's chip) with ONE
   `Positioned(top: 0, left: 0, right: 0)` → `SafeArea(minimum: top 8)` →
   `Column(mainAxisSize: min)` holding the toolbar pill, the selection bar
   (when an aggregate is selected, with a small top gap), and the
   recording dashboard. One SafeArea, one column — nothing can overlap.
2. `map_actions.dart`: `TopToolbar` and `SelectionBar` drop their
   `Positioned`/`SafeArea` wrappers and return the pill itself.
3. `recording_dashboard.dart`: the dashboard stays mounted always (its
   state owns the salvage toast and the model/live listeners); its build
   returns the chip + expandable stats panel as a plain column child
   (`SizedBox.shrink` when idle). The bottom speed readout moves into a
   small `RecordingSpeedReadout` widget in the same file, which `MapPage`
   places as `Positioned(bottom: 24, ...)` — key `recording-speed` and the
   `recordingLive` ListenableBuilder unchanged.
4. Widget tests in `test/map_page_test.dart`: with a fixture imported and
   selected and a fake-source session running, assert `selection-bar` and
   `recording-chip` are both visible and strictly ordered without overlap
   (toolbar bottom ≤ selection top, selection bottom ≤ chip top); idle
   shows neither.

## Slice 2 — persistent keep-screen-on setting replaces the chip's lock toggle (TODO item 2)

Files: `lib/storage/track_store.dart`, `lib/ui/app_model.dart`,
`lib/ui/recording_dashboard.dart`, `lib/ui/settings_sheet.dart`,
`lib/l10n/app_strings.dart`, `test/app_model_test.dart`,
`test/app_strings_test.dart`, `test/map_page_test.dart`

1. `track_store.dart`: `AppSettings.keepScreenOn` (default `true`),
   tolerant `fromMap`, `copyWith`, `toMap`; `TrackStore.keepScreenOn`
   getter + `saveKeepScreenOn(bool)`.
2. `app_model.dart`: `keepScreenOn` getter + `setKeepScreenOn(bool)` with
   the usual `notifyListeners` — the dashboard's model listener applies
   the latch immediately, even mid-session.
3. `recording_dashboard.dart`: remove the `screen_lock_portrait`
   IconButton and `_screenLockOff`; `_applyScreenOn` becomes
   `on = model.isRecording && model.keepScreenOn`, still called from
   `_onModelChanged` on every model change.
4. `settings_sheet.dart`: Android-only row (`Platform.isAndroid`, next to
   the battery advisory) with a `Switch` bound to
   `model.keepScreenOn` / `model.setKeepScreenOn`.
5. `app_strings.dart`: remove `screenStaysOn`/`screenMayTurnOff`; add
   `keepScreenOn` + `keepScreenOnSubtitle` in en and it;
   `test/app_strings_test.dart` updated to match.
6. Tests: `app_model_test.dart` — default true, persists across reload,
   survives `deleteAll`, toggles. `map_page_test.dart` —
   `Icons.screen_lock_portrait` is never rendered (idle and recording);
   a mock on the `unvisited/host` channel records `keepScreenOn` calls:
   `true` at session start, `false` immediately after
   `setKeepScreenOn(false)` mid-session, `false` at stop.
   (The Settings row is Android-only, so like the battery advisory it is
   not built in desktop widget tests.)

## Slice 3 — stop cancels the position stream subscription (TODO item 3)

Files: `lib/recording/recording_session.dart`,
`test/recording_session_test.dart`, `test/recording_controller_test.dart`

1. `recording_session.dart`: `start` stores the `StreamSubscription`;
   `stop()` awaits its cancellation before finalizing the stage, so
   geolocator's foreground service and its notification end with the
   session. `discardRecording` goes through the same `stop()`.
2. `recording_session_test.dart`: after `stop`, a fix pushed to the fake
   source is not processed (pointCount unchanged, `onFix` not called
   again).
3. `recording_controller_test.dart`: after `stopRecording`, a fix pushed
   to the fake source produces no `recordingLive` tick.
4. Manual verification on an Android device (not runnable here): the
   "Recording" foreground-service notification is gone after Stop and
   after Discard — noted in the commit message.

## Verification

- `flutter analyze` clean; `flutter test` passes after each slice.
- Three commits, each removing its TODO.md entry; after each,
  `tool/build_release_apk.sh` is run detached and never awaited.

## Out of scope

- The manual Android notification check (item 3.3) — needs a device.
- Any change to the host channel; `keepScreenOn` already maps to the
  window flag in `MainActivity.kt`.
