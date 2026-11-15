# Code review findings — fix all six TODO.md items

Six small, independent fixes from the 2026-12-19 full-codebase review.

## Changes

1. **`lib/l10n/app_strings.dart`** — remove the duplicate `@override` line on
   `fitTooltip` and `statAvgSpeed` in both `EnglishStrings` and `ItalianStrings`
   (4 spots total).

2. **`lib/ui/stats_panel.dart`** — remove the duplicated first doc-comment line.

3. **`SPEC.md` + `AGENTS.md`** — add `flutter_compass` to the established
   package set (it is already a shipped dependency used by the recording
   dashboard's compass heading; documenting it is less destructive than
   ripping out a working feature).

4. **`lib/ui/import_coordinator.dart` + `android/.../MainActivity.kt`** —
   remove the extension-based pre-filter in folder scans so every file
   reaches the content-sniffing pipeline. In `importFromDirectory` drop the
   `ext` check entirely; in `scanSafTree` copy every regular file (the
   staging copy is the only cost) and let Dart's sniffer decide.

5. **`lib/recording/recording_session.dart`** — add `FixDisposition.ignored`
   and return it from `processFix` when the session is not recording
   (paused/stopped), matching the doc comment's "neither accepted nor
   rejected".

6. **`AGENTS.md`** — add `geolocator` to the quick-reference package list.

## Tests
- `flutter analyze` clean, `flutter test` passes (307+).
- Item 4: existing importer tests already cover content sniffing; the
  folder-scan path is exercised by `import_coordinator_test.dart`.
- Item 5: `recording_session_test.dart` may assert on `FixDisposition` —
  update if it references the paused case.

## Verification
analyze clean, all tests pass; commit PLAN.md + changes + TODO.md removal.
