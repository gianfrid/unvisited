<!-- Open work lives here; completed items are deleted, not ticked. -->

Technical debt backlog (from the codebase debt analysis — refactoring,
code smells, doc drift, test gaps):

1. - [ ] Unit tests for the extracted UI coordinators
   (`import_coordinator`, `recording_controller`, `recording_live`), and
   make `test/tile_server_test.dart` opt-in (network tag) so the default
   `flutter test` runs offline.
2. - [ ] Collapse `AppModel`'s persisted-settings boilerplate (~15
   getter/save pairs) into one settings value object written via
   `_saveIndex`; move `lib/road/road_bench.dart` profiling code out of
   the runtime `lib/` tree.
3. - [ ] Extract the recording dashboard out of `_MapPageState`
   (`map_page.dart`, 1344 lines, the churn hotspot): follow-camera +
   course-up, HUD chip / stats panel wiring, screen latch and salvage
   toast into their own widget; update `map_page_test.dart`.
