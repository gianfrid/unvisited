# PLAN: Fixed-north map orientation (default) with opt-in rotation setting (TODO.md item 1)

TODO.md item: "Fixed-north map orientation (default) with opt-in
rotation setting" — orientation is too buggy, so the map stays north-up
by default (even during recording); a Settings toggle (off by default)
enables the course-up follow-camera rotation. Dynamic rotation is
backlog; the fixed-north limitation is documented in README.md,
ARCHITECTURE.md and SPEC.md.

One commit: setting plumbing + gated rotation + Settings row + strings
+ docs + tests, plus removal of the TODO.md entry. Verification:
`flutter analyze` clean, `flutter test` all pass.

## Current state

- The only rotation in the app is the recording follow-camera's course-up
  in `RecordingDashboard._onRecordingFix`
  (`lib/ui/recording_dashboard.dart`): when the fix carries a reported
  heading, the camera rotates via `moveAndRotate`; a gesture releases
  both follow and rotation. No setting gates it today.
- Settings live in `AppSettings` (`lib/storage/track_store.dart`) as
  string fields persisted in the index's `settings` entry, exposed via
  `TrackStore` getters + save methods and `AppModel` delegating getters/
  setters; the Settings sheet (`lib/ui/settings_sheet.dart`) renders one
  row per setting. Strings live in `lib/l10n/app_strings.dart` (abstract
  `AppStrings` + `EnglishStrings` + `ItalianStrings`); the strings test
  fails on any untranslated entry.
- Tests: `test/map_page_test.dart` has the course-up camera tests
  ('while recording the camera rotates course-up; a pan releases it',
  and the no-heading/bearing test) that assume rotation is always on.

## The change

1. `AppSettings`: new field `mapRotation`, `'off'` (default) or `'on'`;
   `fromMap` falls back to `'off'`, `copyWith` and `toMap` carry it.
   `TrackStore`: getter `mapRotation` + `saveMapRotation`. `AppModel`:
   getter `mapRotation` + `setMapRotation` (notifies listeners).
2. `RecordingDashboard._onRecordingFix`: gate the `moveAndRotate`
   branch on `widget.model.mapRotation == 'on'`. When off, every fix
   takes the plain `move` path — the camera stays north-up while the
   follow still centers on the fix. The marker's own rotation (in
   `map_page.dart`) is untouched: it still points along the course
   relative to the camera.
3. Settings sheet: one new row (SwitchListTile) "Rotate map while
   recording", default off, wired to `model.setMapRotation`.
4. Strings (en + it): `mapRotation` + `mapRotationSubtitle` in
   `AppStrings`, `EnglishStrings`, `ItalianStrings`.
5. Docs:
   - README.md: note near the recording paragraph that the map stays
     north-up by default and rotation is opt-in via Settings.
   - ARCHITECTURE.md: dashboard bullet — fixed-north is the default,
     course-up is the opt-in; dynamic rotation is backlog.
   - SPEC.md: scope item 6 — course-up becomes opt-in (off by default);
     fixed-north documented as the current limitation, dynamic rotation
     in backlog.
6. Tests:
   - `map_page_test.dart`: existing course-up tests run with the setting
     on (set `model.mapRotation = 'on'` in the test setup); add a test
     that with the default off the camera rotation stays 0 while the
     follow still centers.
   - settings round-trip coverage for `mapRotation` in the store/model
     tests; strings test passes via the new en/it entries.
7. Remove TODO.md item 1 in the same commit.

## Out of scope

- Any rotation outside the recording follow-camera (none exists).
- Marker rotation behavior, follow/gesture semantics, tilt (already
  backlog).
- Changing the default for existing users' stored indexes: a missing
  `mapRotation` reads as `'off'`, which is the new intended default.
