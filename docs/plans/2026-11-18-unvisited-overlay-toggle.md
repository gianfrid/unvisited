Implements: TODO.md #1

# "Show unvisited roads" settings toggle

## Problem

The dashed unvisited-roads overlay is always on when a region is
active. At street zoom it draws the entire road network's uncovered
geometry on every settle — informative next to a walk, but heavy as an
unchangeable default, and there is no way to see just the tiles and
one's own corridors. The chip needs no escape hatch (it is small and
region-gated already); the overlay does.

## Design decisions

- **One switch, overlay only.** `AppSettings.showUnvisitedRoads`
  (default true — the just-built behavior; `fromMap` treats a missing
  key as true, matching `keepScreenOn`'s migration pattern). The chip
  is untouched: the numeric question keeps its answer regardless.
- **The row lives in the settings sheet's Road data section and shows
  only with an active region.** Without a region there is nothing to
  toggle (the overlay is already absent), and an inert switch reads as
  a bug.
- **Off means the pass is skipped, not just hidden.** While off,
  `_recomputeViewportCoverage` skips `unvisitedIn` and clears the
  overlay state — no geometry decode per settle. Turning it back on
  recomputes the still-settled viewport immediately, the same mechanism
  region activation uses (a static camera never settles on its own).

## Changes

### `lib/storage/track_store.dart`

- `AppSettings`: `this.showUnvisitedRoads = true`, `fromMap`
  (`(m['showUnvisitedRoads'] as bool?) ?? true`), `toMap`, `copyWith`.

### `lib/ui/app_model.dart`

- `bool get showUnvisitedRoads => store.showUnvisitedRoads;`
- `Future<void> setShowUnvisitedRoads(bool value)`: persist via
  `store.updateSettings` (whatever the existing pattern is — same path
  as `setThemeMode`), then recompute if enabled and corners are
  settled, then notify.
- `_recomputeViewportCoverage`: when the setting is off, skip
  `unvisitedIn` and set `_viewportOverlay` empty; the report pass
  stays.

### `lib/ui/settings_sheet.dart`

- In the Road data section, with a region active: a `Switch` row
  titled "Show unvisited roads" on the existing row styling (same
  shape as the keepScreenOn row), absent otherwise.

### `lib/l10n/app_strings.dart`

- `showUnvisitedRoads` / `showUnvisitedRoadsSubtitle` (EN + IT).

### Tests

1. `test/app_model_test.dart`: toggling off clears the settled
   viewport's overlay state (chip report intact); toggling on restores
   it without a new settle; survives a restart via the settings round
   trip.
2. `test/map_page_test.dart`: settings sheet — the row is absent
   without a region, present with one; switching it off removes the
   dashed polylines while keeping the chip's text (and vice versa).
3. `test/app_strings_test.dart`: the two new entries in the coverage
   map.

## Out of scope

- A per-map quick toggle button (the sheet is the established place).
- Gating the chip (it is small, and any share question it answers is
  region-gated already).
- Persisting per-region preferences.

## Verification

`flutter analyze` clean; `flutter test` green; commit the slice with
this plan file and remove the TODO entry.
