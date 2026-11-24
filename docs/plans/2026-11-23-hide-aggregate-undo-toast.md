# Undo toast after hiding a selected aggregate

Implements: —

The selection bar's hide button currently hides the whole aggregate with
no way back except the tracks drawer. Add an interactable toast: after
`hideSelectedAggregate()`, the map shows a snackbar "Area hidden" with an
**Undo** action that re-shows exactly the tracks that were hidden.

## Change

- `lib/ui/app_model.dart`:
  - `hideSelectedAggregate()` records the hidden member ids in
    `_lastHiddenAggregateIds` (session-only, not persisted) and bumps a
    new `aggregateHideEpoch` counter — the same epoch pattern as
    `fitRequestEpoch`/`importEpoch`, so MapPage can detect the hide.
  - New `undoLastHide()`: re-shows every recorded id still in the
    catalog (`store.setVisible(t, true)`), clears the record, then
    `_catalogDataChanged()`. Re-showing recomputes aggregates, so the
    area comes back on the map and in the drawer immediately.
- `lib/ui/map_page.dart`: `_onModelChanged` compares `aggregateHideEpoch`
  against the last seen value (page field); on a bump it shows a
  `SnackBar` with the `areaHiddenToast` message and a `SnackBarAction`
  labeled `undoAction` wired to `model.undoLastHide()`, duration 6 s so
  there is time to tap. Uses the existing hide-current-then-show
  discipline of `showMapToast` (a rapid second hide replaces the toast).
- `lib/l10n/app_strings.dart`: `areaHiddenToast` ("Area hidden" /
  "Area nascosta") and `undoAction` ("Undo" / "Annulla"), pinned in
  `test/app_strings_test.dart`.
- `test/map_page_test.dart`: select an aggregate, tap `selection-hide`,
  expect all members hidden + the snackbar with the Undo action; tap
  Undo → all visible again and aggregates rebuilt.
- Model test in `test/app_model_test.dart`: hide → `undoLastHide`
  restores visibility; a second hide replaces the undoable set; undo
  after the tracks were deleted is a safe no-op.

## Verify

`flutter analyze` clean, `flutter test` passes. Commit plan + change.
