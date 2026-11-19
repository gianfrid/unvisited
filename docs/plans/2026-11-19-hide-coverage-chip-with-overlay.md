Implements: —

# Hide the unvisited-roads chip while "Show unvisited roads" is off

## Problem

The bottom-left `RoadCoverageChip` ("Unvisited roads here: N%") renders
whenever a road region is active, even with Settings -> "Show unvisited
roads" switched off. The setting currently only suppresses the dashed
overlay, so the chip keeps advertising the feature the user just turned
off. The toggle should remove the whole unvisited-roads presentation
from the map: overlay, chip, and the coverage pass behind them.

## Changes

1. `lib/ui/road_coverage_chip.dart` — return `SizedBox.shrink()` when
   `!model.showUnvisitedRoads`, alongside the existing no-region gate.
   Update the class doc: hidden without a region or with the setting
   off.
2. `lib/ui/app_model.dart` — make the setting the feature switch for
   `_recomputeViewportCoverage`: while off, clear `_viewportReport` and
   `_viewportOverlay` without calling `coverage()`/`unvisitedIn()`, so
   no geometry pass runs and the hidden chip has no stale answer. After
   each await, also bail on `!showUnvisitedRoads` so a pass already in
   flight cannot land after the user switched it off.
   `setShowUnvisitedRoads` keeps recomputing the still-settled viewport
   both ways (off clears, on restores report and overlay). Update the
   doc comments that currently say the chip answers regardless.
3. Comments in `lib/storage/track_store.dart` (the `AppSettings` field
   doc), `lib/ui/settings_sheet.dart` (toggle-row comment), and
   `lib/ui/map_page.dart` (bottom-column comment), plus the closing
   sentence of the road-coverage paragraph in `ARCHITECTURE.md`: off
   skips the whole pass and hides the chip too, not just the dashes.
4. Tests:
   - `test/app_model_test.dart`, "the unvisited overlay toggle skips and
     restores the pass": off now expects `viewportReport` to be null as
     well as the overlay empty; on expects both restored, with the
     walked way still absent from the overlay.
   - `test/map_page_test.dart`, "the overlay toggle switches the dashed
     layer off": expect the chip text to disappear when the switch goes
     off (instead of "chip stays"); flip the switch back and expect both
     the dashes and the chip to return.

## Verification

`flutter analyze` clean, `flutter test` green. Manual desktop check:
activate a road region — chip shows; Settings -> off — dashed layer and
chip both disappear; on — both return without a camera move. Commit only
this slice's files; the unrelated local AppImage/desktop working-tree
changes stay untouched.
