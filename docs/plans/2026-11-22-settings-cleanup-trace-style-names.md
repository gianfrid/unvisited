# Settings cleanup: drop the rotate-map row, rename Fog style → Trace style, Italian "Percorso"

Implements: — (direct user request)

Three label/row changes:

1. **Remove the "Rotate map while recording" row from Settings** — the
   rotation is now toggled from the always-visible control-pill button, so
   the Settings row is redundant.
2. **Rename "Fog style" → "Trace style"**, and its "Lines" option →
   "Pencil".
3. **Italian spelling**: the course rotation label "Corso su" →
   "Percorso su".

## Design

1. `lib/ui/settings_sheet.dart` — delete the map-rotation `ListTile` +
   `SegmentedButton` block. The persisted `settings.mapRotation` value and
   the model/store plumbing **stay**: the control-pill button
   (`map_controls.dart`) and the recording/playback dashboards still drive
   and read it. Only the sheet row goes. The now-unused strings
   `mapRotation` / `mapRotationSubtitle` are removed from the abstract
   class, both languages, and the coverage-test map; `rotationModeNorth` /
   `rotationModeCourse` stay (the HUD button's labels use them).
2. `lib/l10n/app_strings.dart` — rename the fog-style getters to
   `traceStyle`, `traceStyleSubtitle`, `traceStyleCircles`,
   `traceStylePencil`, `traceStyleInk` with values "Trace style" /
   "How explored areas are drawn" / "Circles" / **"Pencil"** / "Ink"
   (Italian: "Stile della traccia" / … / "Cerchi" / **"Matita"** /
   "Inchiostro"). The persisted JSON key stays `fogStyle` — renaming the
   label only, no index migration. `settings_sheet.dart` and the tests
   move to the new getters.
3. `rotationModeCourse` Italian: "Corso su" → "Percorso su".
4. Tests — `test/app_strings_test.dart` allStrings map updated (removed
   rotation-row strings, renamed trace strings); `test/map_page_test.dart`
   fog-style test taps "Pencil" / closes via "Trace style".
5. Docs — SPEC item 6, the ARCHITECTURE recording paragraph and the
   README recording bullet currently point at Settings → "Rotate map
   while recording"; reword to the control-pill rotation button.
6. Verify: `flutter analyze` clean, `flutter test` passes; commit plan +
   change in one commit.
