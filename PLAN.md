# Plan — resolve technical debt (TODO.md technical debt, items 1 and 2)

## Phase A — recording live state gets its own Listenable (item 2)

Problem: `AppModel.notifyRecordingFix` calls `notifyListeners()` on the whole
model at 1 Hz; `MapPage._onModelChanged` then rebuilds the entire map tree,
and `recording.liveSegments` deep-copies every segment on each rebuild.

Change:

1. New `RecordingLiveState extends ChangeNotifier` (lives in
   `lib/ui/recording_live_state.dart` or next to the model) that owns the
   per-fix payload the UI reads at 1 Hz: a reference to the current
   `RecordingSession` (or its stats/segments/marker getters). The model
   exposes it as `model.recordingLive`; `notifyRecordingFix()` notifies
   only that notifier.
2. `MapPage` keeps its existing `model.addListener(_onModelChanged)` for
   structural changes (imports, visibility, settings, recording
   start/stop) and adds a separate listener on `recordingLive` for the
   per-fix path: follow-camera move/rotate, HUD chip, stats panel, marker,
   live trace. Those subtrees wrap in `AnimatedBuilder`/`ListenableBuilder`
   on `recordingLive` so the fog overlay and toolbar do not rebuild per fix.
3. `liveSegments` in `RecordingSession` keeps returning copies (it must —
   the writer mutates them), but they're now copied once per fix into the
   live subtree's rebuild, not per model-wide rebuild.

Tests: existing `map_page_test.dart` recording tests must pass unchanged
(they assert chip/marker/camera behavior); add one test asserting the fog
overlay widget does not rebuild on a fix (e.g. via a spy/counter or by
checking `AnimatedBuilder` scoping) — at minimum the existing widget tests
green proves no behavior regression.

## Phase B — split app_model.dart (item 1)

Problem: 869 lines, 6 concerns in one ChangeNotifier.

Change (file layout):

- `lib/ui/app_model.dart` — keeps `AppModel` (settings, locate, visibility,
  delete, load), `MapTrack`, `ImportSummary`, `LocateResult`, and exposes
  the two extracted collaborators as fields.
- `lib/ui/recording_controller.dart` — `RecordingController extends
  ChangeNotifier`: start/stop-with-name/pause/resume, staging path,
  salvage on load, screen latch, battery advisory, `recordingName`. Holds a
  back-reference to the model for the import-on-stop and road matching.
- `lib/ui/import_coordinator.dart` — `ImportCoordinator`: one
  `importBytes(bytes, filename, {source})` helper performing the shared
  store+roads+cache+summary choreography (`_importBytes`,
  `_noteImported`/`_recordNewImports`, `_matchRoads`/`_matchTrack`,
  `notifyListeners`); `importFromFile`, `importFromDirectory`,
  `importViaFilePicker`, `importViaDirectoryPicker`, `_importSafTree`
  collapse onto it.
- Call sites in `map_page.dart`, `track_list.dart`, `settings_sheet.dart`
  updated to `model.recording.*` / `model.imports.*` where they belong.
  Mechanical renames, no behavior change.

Tests: full `flutter test` suite (app_model_test, map_page_test) must pass
unchanged; analyze clean.

## Order and commits

Two commits: Phase A first (smaller, independently verifiable), then
Phase B. PLAN.md committed with each; TODO.md debt items removed in the
same commits.
