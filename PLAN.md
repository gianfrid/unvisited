# PLAN: Technical debt backlog (debt analysis follow-up)

TODO.md item: "Technical debt backlog" (5 units). Executed as five
independent commits, low-risk first and the big widget refactor last, so
every commit leaves `flutter analyze` clean and `flutter test` green.
Each commit removes its own TODO.md unit entry. Verification after every
commit: `flutter analyze` clean, `flutter test` all pass.

## Unit 1 — Stale docs (commit 1)

1. `README.md`: rewrite the `lib/` project-layout tree to match the real
   tree — add `aggregate/`, `recording/`, `road/`, `geo.dart`,
   `build_version.dart`, and list the actual `ui/` modules (or describe
   the folder generically instead of naming three files).
2. `lib/storage/track_store.dart`: fix the `TrackStore` class comment —
   it still says a FIT/GPX re-export "may still appear twice"; describe
   the implemented cross-format dedup (start ±2 s + distance within 10%,
   per SPEC) alongside the byte-hash dedup.
3. `ARCHITECTURE.md`: fix the fog-of-war paragraph — the overlay is drawn
   per aggregate in the aggregate's resolved tint (see
   `AppModel.aggregateTintKeys`, `map_page.dart`), not "a single tint";
   add `import_coordinator.dart`, `recording_controller.dart`,
   `recording_live.dart` to the UI module list.
4. Remove TODO.md unit 1.

## Unit 2 — Type-safe outcomes + shared constants (commit 2)

1. `lib/storage/track_store.dart`: introduce a sealed
   `ImportOutcome` (imported / duplicate / skipped(reason) /
   failed(error)) and have `ImportResult` carry it instead of the raw
   `String? reason`.
2. `lib/ui/import_coordinator.dart`: switch `ImportSummary.add` from
   string matching ('duplicate', 'skipped:' prefix) to a `switch` over
   the sealed type.
3. `lib/ui/recording_controller.dart`: update its use of import results
   to the new type.
4. `lib/ui/map_page.dart` + `lib/ui/fog_of_war.dart`: delete the inline
   `metersPerPixelAtEquatorZoom0 = 156543.03392` in `_hitToleranceMeters`
   and call `groundResolution()` from `fog_of_war.dart` instead.
5. `lib/ui/app_model.dart`: one `_mimeFor(format)` helper replacing the
   three inline `?? 'application/octet-stream'` fallbacks.
6. Tests: extend `track_importer_test.dart` / `app_model_test.dart` for
   the outcome type; remove TODO.md unit 2.

## Unit 3 — Coordinator tests + offline test suite (commit 3)

1. New `test/import_coordinator_test.dart`: drive `ImportCoordinator`
   against a temp-dir `TrackStore` with fixture files — assert summary
   counters per outcome, point-cache remember/invalidate, epoch bumps.
2. Extend `test/app_model_test.dart` (or a new
   `recording_controller_test.dart`) for `RecordingController`
   start/stop/discard/pause/resume with a fake `PositionSource`, and the
   salvage path.
3. `test/tile_server_test.dart`: tag the network tests
   (`@Tags(['network'])`) and document running them with
   `flutter test --tags network`; default `flutter test` then runs
   offline. Remove TODO.md unit 3.

## Unit 4 — Settings boilerplate + road_bench placement (commit 4)

1. `lib/storage/track_store.dart`: group the persisted settings (tint,
   recordingTint, zoomSliderSide, language, themeMode, tileLayer,
   roadsFile, lastPosition) behind one `SettingsSnapshot` value object
   read/written as a single `settings` map in `index.json`; keep
   individual getters as thin delegates so callers don't change.
2. `lib/road/road_bench.dart`: move the bench out of `lib/` into `tool/`
   (pure Dart, no Flutter — only `app_model.dart`'s `kProfileMode`
   trigger imports it; that trigger moves behind a thin seam or is
   dropped in favor of the CLI). Remove TODO.md unit 4.

## Unit 5 — Extract recording dashboard from `_MapPageState` (commit 5)

1. New `lib/ui/recording_dashboard.dart`: a widget owning the follow-camera
   logic (`_onRecordingFix`, `nearestEquivalentRotation` use,
   `_followRecording` arm/release), the HUD chip + stats panel expansion
   (`_dashboardOpen`), the screen-latch toggle (`_screenLockOff`,
   `_applyScreenOn`), and the salvage toast; it listens to
   `model.recordingLive` itself and drives the `MapController` handed
   down by `MapPage`.
2. `lib/ui/map_page.dart`: delete the moved state/methods; keep map
   events, fog cache, selection, locate and import refits. Target:
   well under 900 lines.
3. `test/map_page_test.dart`: keep all existing assertions passing
   unchanged (the dashboard's widget keys/labels must survive the move);
   add a widget test for the extracted dashboard if behavior is new.
   Remove TODO.md unit 5.

## Out of scope for this plan

No behavior changes, no new packages, no SPEC scope additions. If any unit
surfaces a surprise (e.g. unit 5's extraction changes widget keys the
tests rely on), stop, report, and re-plan that unit rather than forcing
it through.
