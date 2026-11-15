# PLAN: Post-debt-backlog residuals (TODO.md, 2 units)

TODO.md item: "Post-debt-backlog residuals" — (1) shrink `map_page.dart`
further, (2) tighten `RecordingDashboard`'s per-fix rebuild scope. Two
independent commits, unit 2 first (smaller, fully local to the new
file), unit 1 second. Verification after each commit: `flutter analyze`
clean, `flutter test` all pass (the 4 opt-in network checks stay
skipped). Each commit removes its TODO.md unit entry. No behavior
change: widget keys, strings and geometry must stay identical.

## Current state

- `lib/ui/map_page.dart` is 1090 lines after the dashboard extraction.
  Its `build()` (~lines 745–1090) is a ~345-line Stack: the FlutterMap
  config (~150 lines), zoom slider pill, top toolbar pill, selection
  bar pill, bottom-left action stack (~70 lines), `RecordingDashboard`,
  empty-state hint and busy bar. The recording/import/settings handlers
  (`_stopRecording` ~80 lines of dialog, `_chooseImport`/`_openSettings`/
  `_pickFiles`/`_pickFolder`, `_locate`/`_silentPositionUpdate`,
  `_selectionActions` ~60 lines) make up most of the rest.
- `lib/ui/recording_dashboard.dart` (362 lines) builds through
  `ListenableBuilder(listenable: Listenable.merge([model,
  recordingLive]))`, so every 1 Hz fix repaints chip + stats panel +
  speed card + latch icon.

## Unit 2 (commit 1) — narrow the dashboard's per-fix rebuild

1. In `RecordingDashboardState.build`: drop the merge; return
   `ListenableBuilder(listenable: widget.model.recordingLive, ...)`
   around only the session-driven readouts (chip text, stats panel,
   speed card). Boundary/latch changes already rebuild the widget via
   `_onModelChanged`'s `setState`, so the model listener is not needed
   in the builder.
2. Keep the latch toggle and panel toggle as dashboard `setState`
   (user actions, not per-fix).
3. Remove TODO.md unit 2.

Watch: `map_page_test.dart` tests 'the recording camera follows the
fixes; a pan releases it', 'while recording, locate returns the follow
after a pan', the latch test ('the recording latch keeps the screen
on; the toggle opts out') and the chip/panel tests — all must pass
unchanged.

## Unit 1 (commit 2) — shrink map_page.dart below ~900 lines

Extract the three chrome pills and the bottom action stack into
`lib/ui/map_actions.dart` (the toolbar's home) as widgets returning
`Positioned` (valid as direct Stack children of map_page's Stack):

1. `TopToolbar` — the existing `Positioned(top/left/right, SafeArea,
   FloatingToolbar)` block with Import/Tracks/Settings, taking `model`,
   `strings`, and callbacks `onImport`, `onOpenTracks`, `onOpenSettings`.
2. `SelectionBar` — the selection pill, from `_selectionActions`; takes
   `model`, `strings`, and an `onFit` callback (the `_fitWhenSized` call).
3. `BottomActionStack` — the locate/record/pause/stop pill: takes
   `model`, `locationSupported`, `locating`, `gpsWorking`, and callbacks
   `onLocate`, `onRecord`, `onStop`, `onPauseResume`. The stop dialog
   (`_stopRecording`'s showDialog chain) moves into this widget (it
   needs only the model and strings).
4. `map_page.dart` keeps: map controller + event wiring, fog cell size,
   camera fits, the FlutterMap layer stack (tiles/fog/corridors/
   selection highlight/trace/locate marker/recording marker), the
   locate/silent-fix logic (`_locate`, `_silentPositionUpdate`, retry
   timer, `_gpsWorking`, `_locating` — the stack receives them as
   flags), `_onModelChanged`, imports and toast.
5. Update TODO.md unit 1 removal; ARCHITECTURE.md's UI sentence already
   lists `map_actions.dart` — extend its parenthetical to name the new
   widgets.

Watch: the geometry of the pills (keys `selection-bar`, `stop-discard`,
`stop-discard-confirm`, `recording-chip` etc. live in the moved widgets)
and the bottom-stack tests ('locate and record live in the bottom-left
stack', record/pause/stop flows, discard two-step). All assertions must
pass unchanged; only widget-ownership moves.

## Out of scope

No behavior or string changes, no new packages, no further map_page
slimming beyond these three pills + action stack (if the file still
exceeds ~900 after them, report the remainder instead of forcing it).
