# Fog style follows the selection highlight; ink strokes sized in meters (10 m)

Implements: — (direct user request, follow-up to 2026-11-22-fog-style-settings)

Two fixes to the fog-style feature:

1. **Selection highlight follows the active style.** Today the selected
   aggregate's highlight is always unlock *circles*
   (`_selectionHighlight`), even in polyline/ink mode — the "multitrack"
   selection should read in the same style the map is drawn in.
2. **Ink strokes get a ground-truth size.** flutter_map polyline widths
   are screen pixels, so the ink style currently shrinks/grows with zoom
   like a screen-space line. The user wants ~10 m — deliberately below the fog's 15 m unlock
   radius — so ink stroke widths must be meter-based, converted to pixels
   per frame via `groundResolution` (already in `fog_of_war.dart`).

## Design

### 1. Style-following selection highlight (`map_page.dart`)

`_selectionHighlight()` becomes style-aware, mounted as the matching layer:

- `circles` — unchanged (translucent-boosted `CircleMarker`s).
- `polyline` — the selected aggregate's segments as solid (alpha 1)
  polylines in its resolved tint, thin dark border — visibly "selected"
  against the translucent line fog.
- `ink` — the selected aggregate's segments drawn as ink passes in the
  ink hue at full opacity.

### 2. Meter-based ink width

- `ink_stroke.dart`: new `inkWidthMeters = 10.0` — the base stroke width in ground
  meters, deliberately below the fog's 15 m unlock radius so the two
  reads stay distinct; pass width factors multiply it (bleed ≈ 22 m,
  core ≈ 7 m).
- `map_page.dart`: pixel width = `inkWidthMeters * pass.width /
  groundResolution(zoom, latitude)` from the live camera. Ink *geometry*
  (the jittered strips) is zoom-independent after band decimation, so it is
  cached per aggregate @ band exactly like the circle centers; only the
  thin `Polyline` wrappers are rebuilt with the current px width.
- Rebuild trigger: the map-event listener already setStates on fog-band
  crossings; it additionally tracks a zoom step quantized to 0.5
  (`_fogZoomStep`), so ink width refreshes twice per zoom level without
  per-frame recomputation of the stroke geometry. Pans and same-step zooms
  are cache hits.

## Steps

1. `lib/ui/ink_stroke.dart` — `inkWidthMeters` constant (10 m, below the
   fog's 15 m unlock radius); doc note that widths are ground meters, converted
   by the caller.
2. `lib/ui/map_page.dart` —
   - `_fogZoomStep` state + dirty check in the map-event listener;
   - `_buildFogLines` computes `pxPerMeter` from the camera and sizes ink
     strokes in meters; ink strip geometry cached per aggregate @ band;
   - `_selectionHighlight` → style-aware (`_buildSelectionLayer`), mounted
     as `CircleLayer`/`PolylineLayer` accordingly.
3. Tests:
   - `test/ink_stroke_test.dart` — `inkWidthMeters` is 10 m, below the unlock radius.
   - `test/map_page_test.dart` — ink mode renders wider strokes than the
     polyline style, and the width matches 10 m at the test camera's
     zoom; selecting an aggregate in polyline mode highlights with a
     `PolylineLayer` (no highlight `CircleLayer`).
4. Docs — one clause in ARCHITECTURE.md's rendering paragraph (highlight
   follows the style; ink is meter-sized); SPEC.md item 5 unchanged in
   substance (already says the style is selectable).
5. Verify: `flutter analyze` clean, `flutter test` passes; commit plan +
   change in one commit.
