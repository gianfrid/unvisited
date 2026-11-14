# PLAN — Stop with name at the record slot (pause → resume, stop asks a name)

TODO unit: "Recording — map controls & camera", item 1.

Goal: while a session runs the record slot shows Pause only; pressing it
flips the slot to Resume and a Stop action appears before it in the same
stack (moving out of view again once resumed). Stop opens a name dialog
defaulting to the current date-time timestamp and finalizes the session
through the unified import pipeline under that name. The dialog's cancel
keeps the session recording.

## Design

- The stack's states (`lib/ui/map_page.dart`, the recording branch):
  running → [Pause, Locate]; paused → [Stop, Resume, Locate]; idle →
  [Record, Locate]. Stop is only visible while paused — the running state
  no longer shows it, per the TODO wording ("stop ... appears before it"
  once the slot turned to resume).
- The name rides the GPX `<name>`, which the parser (and so the catalog)
  already reads; the staged header was written at session start with the
  start timestamp, so the chosen name is written into the finalized bytes
  before the import: a new pure-Dart helper `renameGpxTrack(gpx, name)` in
  `lib/recording/staging_gpx.dart` replaces the first `<name>…</name>`
  element's content (escaped like the writer escapes) and returns the
  input unchanged when the element is absent. No pipeline change: a
  recorded track is still an ordinary catalog track through
  `_importRecordingBytes` (dedup, point-cache invalidation, road
  corridors), just under the chosen name.
- `AppModel.stopRecording({String? name})` applies the rename after the
  session stopped and before the import; `null` keeps today's behavior
  (the start timestamp). The start-timestamp format moves to a public
  `recordingName(DateTime)` so the dialog's default and the staged name
  share one rule. The startup salvage path is untouched — killed sessions
  keep the start-timestamp name.
- The dialog (`showDialog<String>`, like the delete confirms): title
  `stopRecordingTitle`, a `TextField` seeded with
  `model.recordingName(DateTime.now())` and labelled `recordingNameLabel`,
  Cancel → null (session keeps running), confirm (existing `stopLabel`)
  → the trimmed text, an empty field falling back to the default so the
  confirm button never has to disable. Strings en + it; the strings test
  pins coverage.
- Stop with zero accepted points keeps today's behavior: empty bytes
  import nothing, the staged file is removed. The dialog shows either way
  — a stop is a stop.

## Implementation steps

1. `lib/recording/staging_gpx.dart`: add `renameGpxTrack`; tests in
   `test/recording_session_test.dart` (next to the salvage tests): rename
   round-trips through `GpxParser` (`TrackData.name` carries the new
   name), `& < >` escaping, no-`<name>` passthrough, and the default
   invariance for an already-correct name.
2. `lib/ui/app_model.dart`: `stopRecording` gains the optional `name`
   (utf8 rewrite via the helper when non-null), `_recordingName` becomes
   public `recordingName`; model test in `test/app_model_test.dart`:
   a custom name stop imports the catalog entry under that name, a
   nameless stop keeps the start timestamp.
3. `lib/ui/map_page.dart`: rework the recording branch of the stack; the
   Stop `_HeaderAction` moves behind the paused state and its tap opens
   the name dialog before calling `stopRecording(name:)`.
4. `lib/l10n/app_strings.dart`: `stopRecordingTitle` and
   `recordingNameLabel` (English + Italian) near the existing recording
   strings.
5. Tests in `test/map_page_test.dart`: while running — no Stop, Pause in
   the slot; tap Pause → Stop appears before the Resume slot (rect
   assertions like the stack test), resume hides Stop again; Stop tap →
   dialog with the default timestamp in the field, cancel keeps the
   session; re-tap, confirm → session cleared. Update the existing
   assertions that expect Stop visible while a session runs.
6. Docs: ARCHITECTURE.md recording/location bullets (stack layout,
   stop-with-name), SPEC.md item 6 clause. TODO.md: remove the unit (the
   section goes away). PLAN.md (this file) is committed with the change.

## Out of scope

- Resume of a killed session, auto-pause-when-stationary, interval
  setting, the tilt/3D backlog, aggregate selection, Fit removal, the
  package rename, the track-list menu (separate units).
- No new packages, no pipeline or salvaging change.

## Verification

`flutter analyze` clean; `flutter test` green; manual on Android:
pause → Stop appears and the slot reads Resume; stop → the name dialog
proposes the timestamp, confirming lands the track in the catalog under
that name; cancelling the dialog keeps the session recording.
