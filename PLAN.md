# PLAN — Test harness extraction (Technical debt 1)

TODO unit: "Technical debt": `mockGeolocator` and the repeated
createRoot/temp-dir/MaterialApp setup (43 copies) become shared helpers
in `test/helpers.dart`.

## Helpers (into test/helpers.dart)

- `createRoot()` / `createCache()` — temp directories with best-effort
  teardown (the two cleanup blocks that repeat verbatim).
- `createModel([root])` — `AppModel(TrackStore(root))` + `load()`,
  shared by the widget and model tests.
- `pumpMapPage(tester, {model, cache, locationSupported, buildTime})` —
  the standard MaterialApp/MapPage pump with the fixed build time
  (`testBuildTime`; one display test overrides it).
- `FakePositionSource` — the fix stream the recording tests push
  through, currently defined twice (map_page_test.dart, app_model_test.dart).
- `mockGeolocator(tester, …)` — moves out of map_page_test's `main()`
  (its body is unchanged).

## Implementation steps

1. Add the helpers to `test/helpers.dart`; both big test files drop
   their local copies (`createRoot`, `mockGeolocator`, `FakePositionSource`
   ×2). parser tests keep importing only what they use.
2. Collapse the boilerplate mechanically in `test/map_page_test.dart`:
   the createRoot+AppModel+load pair → `createModel(root)`, the
   cache block → `createCache()`, the pump block → `pumpMapPage(...)`.
   Tests that interleave `importBytes` between model creation and
   `load()`, and the two non-standard pumps (the buildTime-display test,
   the desktop test), are updated by hand to keep the order semantics.
3. Same follow-along in `test/app_model_test.dart` (createRoot/AppModel
   pairs, FakePositionSource deletion).

## Out of scope

No assertion changes, no reordering of pumps, no test renames; the
point is the harness, not the tests' content.

## Verification

`flutter analyze` clean; `flutter test` 239/239; the diff reviewed so
that every hunk either replaces boilerplate with a helper call or
deletes a local copy.
