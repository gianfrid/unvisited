# Slice 11 — "No tracks yet" hint must not block the view

## Context

The map's empty-state card shows when `mapTracks.isEmpty`, i.e. when no
*visible* track plots. Two bug reports:
1. While a recording session runs, the hint sits on top of the dashboard
   (map has no plotted track yet) — blocking the view.
2. With tracks imported but all deselected, `mapTracks` is empty, so the
   hint claims "No tracks yet" even though the catalog is full.

## Steps

1. `lib/ui/map_page.dart` — the hint's gate becomes:
   `model.tracks.isEmpty && !model.isRecording`
   (the drawer's `nothingImportedYet` label is a different widget — the
   drawer list — and stays as-is; it correctly says the catalog is empty).
   The map hint then shows only on a genuinely empty, non-recording map.
   The Fit action's `mapTracks.isEmpty` disable stays as it is — deselected
   tracks correctly disable Fit, that is not part of the bug.
2. Tests (`test/map_page_test.dart`):
   - with one imported track visible → no hint;
   - same track deselected (toggle its checkbox in the drawer or
     `model.setVisible(track, false)` + pump) → no hint on the map;
   - empty catalog, not recording → hint visible;
   - empty catalog while recording (start a fake-sourced session) → no
     hint, dashboard chip present.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 11 TODO entry; PLAN.md
  carries over to the next task unmodified.
