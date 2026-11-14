# Plan — Stop popup: Save + Discard (TODO.md "Recording dashboard UX (triage)", unit 1)

`_stopRecording` (`lib/ui/map_page.dart:458`) today offers Cancel +
"Stop" (FilledButton). Rename the confirm action to **Save** and add a
**Discard** action that ends the session and throws the recording away.

## Steps

1. **Strings** (`lib/l10n/app_strings.dart`): add `saveLabel` ('Save' /
   'Salva') and `discardLabel` ('Discard' / 'Scarta') to the abstract
   interface, the English and the Italian class. The every-language
   coverage test (`test/app_strings_test.dart:124`) enforces both.
2. **Controller** (`lib/ui/recording_controller.dart`): add
   `discardRecording()` — same session-teardown as `stopRecording`
   (`_recording = null; _recordingFile = null; onChanged();
   await session.stop();`) but the staged file is deleted and never read,
   finalized or imported. Critical detail: the file must be deleted even
   though startup salvage imports any leftover under `recording/` —
   a discarded session must not resurrect on next launch.
3. **Model passthrough** (`lib/ui/app_model.dart`):
   `Future<void> discardRecording() => recorder.discardRecording();`
   next to `stopRecording`.
4. **Dialog** (`map_page.dart` `_stopRecording`): the dialog's
   `showDialog<String>` result gets a third outcome. Layout:
   - `TextButton` Cancel (unchanged, pops null),
   - `TextButton` Discard (red `foregroundColor` from the error scheme)
     popping a sentinel (e.g. the empty string) — not the name field's
     value, so a stray empty-name result can't mean both;
   - `FilledButton` Save (was "Stop") popping the trimmed-or-default name
     as today.
   After the dialog: name non-null → save path as today (`stopRecording`);
   sentinel → a second confirmation dialog ("Discard recording?") whose
   Cancel pops back to recording untouched and whose destructive Discard
   → `discardRecording`. Two-step per user confirmation — the first
   Discard button asks before data is destroyed.
5. **Tests**:
   - Controller unit test (Rec `recording_session_test.dart` or a new
     block): start + feed + discard → staged file gone, nothing in the
     catalog, a subsequent `salvageRecordings()` imports nothing.
   - Widget test(s) in `map_page_test.dart` mirroring the existing
     stop-dialog tests (FakeAsync-aware, see their comments): Save label
     appears in the dialog and keeps the existing finalize flow; Discard
     ends the session (chip gone, no new track); Cancel keeps recording.
6. `flutter analyze` + `flutter test`; commit with this PLAN.md and the
   unit-1 entry removed from TODO.md.

## Notes

- Title stays "Stop recording"; only the action labels change (Save/Discard).
- Desktop has no recording, no new platform concerns; UI-only + controller.
