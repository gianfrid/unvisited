# Ink fog style: kill the rebuild storms

Implements: —

## Diagnosis (why ink feels slow vs circles/polyline)

1. **Per-half-zoom page rebuilds (ink-only).** The map-event listener in
   `map_page.dart` marks the page dirty whenever the zoom crosses a half-step
   while `fogStyle == 'ink'` (the stroke widths convert ground meters to
   pixels at build time via `_pxPerMeter()`). Every such `setState` rebuilds
   the whole page, creates a new `PolylineLayer` widget instance, and
   flutter_map's `didUpdateWidget` then clears its projection + simplification
   caches — so every strip of every aggregate (3 passes, up to
   `inkMaxStripsPerTrack` strips per segment) is re-projected and
   re-simplified, and `_buildFogLines` re-allocates every strip `Polyline`.
   A pinch zoom crosses ~2 half-steps per zoom level: repeated full-catalog
   storms. Circles/polyline only rebuild on whole fog-band crossings.
2. **Every model notification rebuilds the layer.** `_onModelChanged` ends in
   `setState`, and the viewport-settle debounce notifies after every gesture.
   In ink mode that recreates thousands of strip `Polyline` objects and
   re-projects them, even though the stroke geometry (`_inkPassesCache`) is
   already cached — the pixel width was the only zoom-dependent part.
3. Per-frame paint during gestures (3 passes × decimated points, meter-wide
   strokes) is inherent to the ink look and is not changed.

## Changes (all in `lib/ui/map_page.dart` + one test)

1. Draw ink polylines with `useStrokeWidthInMeter: true` and `strokeWidth`
   in meters (`inkWidthMeters * pass.width`) in `_buildFogLines` and
   `_selectionHighlightLayers`. flutter_map converts meters to pixels at
   paint time per polyline (`metersToScreenPixels`), identical result to the
   current camera-center conversion. Then:
   - drop the `fogStyle == 'ink'` clause from the half-step dirty check
     (member-picking lanes keep theirs — lane spacing is genuinely zoom-
     dependent);
   - remove the now-unused `_pxPerMeter()`; keep `_cameraZoom` (lanes).
2. Memoize the fog line `PolylineLayer` widget itself, keyed by
   style + `_fogCellSize` + per-aggregate signature
   (`anchorId[member ids]tintKey`). Returning the identical widget instance
   makes Flutter skip `didUpdateWidget`, so model-notification rebuilds no
   longer re-project/re-simplify the catalog. Applied to both line styles
   ('polyline' and 'ink'); circles untouched.
3. Key `_inkPassesCache` by member ids joined (like `_buildFogCircles`) —
   `anchorId` alone is stable across membership changes and could serve
   stale strokes at the same band.
4. Update the ink widget test in `test/map_page_test.dart`: assert
   `strokeWidth` values in meters (`inkWidthMeters * passWidthFactor`) and
   `useStrokeWidthInMeter == true`, instead of pixel widths.

## Verification

- `flutter analyze` clean.
- `flutter test` green (esp. `map_page_test.dart` ink test,
  `ink_stroke_test.dart`).
- Expected behavior after: ink mode rebuilds only on fog-band crossings,
  same as the other styles; no re-projection on gesture-settle notifies.
