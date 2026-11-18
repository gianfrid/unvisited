Implements: TODO.md #2

# Unvisited-roads overlay (unit 2 of "Show unvisited roads")

## Problem

Unit 1 answers the question numerically: the chip says what share of
the viewport's road meters is unvisited. The final objective is the map
surface showing *which* roads those are — the next place to go,
in place. What exists: decoded bucket geometry in `RoadStore` (8-bucket
LRU of parsed ways), per-track corridor polylines persisted in
`index.json`, the `ViewportCoverage` rectangle/epoch memoization, and a
300 ms settle-debounce in the map page. What is missing: turning
way-geometry-minus-corridors into on-screen polylines.

## Design decisions

- **Unvisited = the uncovered stretches of each way, not whole ways.**
  A way walked end-to-end draws nothing; a way touched at one end draws
  only its dark end. This is the honest inverse of the corridor layer
  (which lights covered stretches, never whole ways) and reuses the same
  granularity the matcher already persists.
- **Corridor → meter interval by walking geometry.** A corridor is the
  way's own geometry cut at meter offsets, so every corridor point lies
  on the way line. Projecting sequentially (two-pointer nearest-segment
  match, hot-started per way) is linear and tolerates geometry drift on
  a re-extract (way ids stable, geometry not identical). Each corridor
  yields one interval `[first offset .. last offset]`; intervals merge,
  and the complement against `[0, total length]` is cut into
  sub-polylines.
- **Shared geometry helpers extracted from the matcher.** The matcher's
  private `_merge`/`_cut` move to a public `lib/road/way_geometry.dart`
  (`mergeIntervals`, `cutGeometry`, plus new `unvisitedStretches` and the
  projection helper). The matcher delegates — its tests already pin the
  behavior, so the extraction is refactor-only. No interval-persistence
  change (plan of unit 1 ruled a format change out; this stays so).
- **Visible tracks only — unifying chip and overlay.** The corridor
  layer draws visible tracks only; hiding a track must also return its
  roads to "unvisited", or hidden state would show grey roads while the
  chip counts them discovered. So `mergedCorridors()` (unit 1) switches
  from all tracks to visible tracks too: hiding a track now changes
  both the number and the drawing, consistently. Track *matching*
  (rematch, persistence) stays unconditional — visibility is
  presentation, unlock state remains exploration data.
- **Drawing floor tighter than the chip's.** The chip answers at 6×6
  tiles; drawing every unmatched way across that much city is dense
  noise and tens of thousands of polylines. The overlay draws when the
  viewport spans ≤ 3×3 z12 tiles (a street/city-quarter view). Below it
  the layer is simply absent — the chip keeps talking.
- **No extra cache.** The overlay pass re-reads buckets through the
  store's own 8-bucket LRU (one transient decode per settle; geometry
  is GC'd after building the layer list). `ViewportCoverage` grows the
  geometry pass instead of a parallel class — same rectangle+epoch memo
  discipline, one more memoized result.
- **Style: dashed, neutral "ink", under the fog.** Dashed (flutter_map
  `StrokePattern.dashed`, verified in 8.3.2) in a muted blue-grey at
  ~55% alpha, strokeWidth 3 — deliberately outside the exploration tint
  family, reading as "background target", not as an unlocked thing.
  Layer order: above tiles, below the fog circles and corridors, so
  discovered things always paint over the roads they discovered.

## Changes

### `lib/road/way_geometry.dart` (new, pure Dart)

1. `mergeIntervals(List<List<double>>)` — moved from the matcher.
2. `cutGeometry(List<LatLng> way, double fromM, double toM)` — moved.
3. `offsetOf(List<LatLng> way, LatLng p, {int startSegment})` →
   `(double meters, int segment)` — nearest-segment projection with a
   caller seed for the sequential corridor walk.
4. `unvisitedStretches(List<LatLng> way, List<List<LatLng>> corridors)`
   → `List<List<LatLng>>` — project-merge-complement-cut as above;
   `const []` when fully covered.

### `lib/road/road_matcher.dart`

- `_merge`/`_cut` bodies become delegations to `way_geometry.dart`.
  No behavior change; existing tests stay untouched as the pin.

### `lib/road/road_coverage.dart`

1. `OverlayWay` record: way id + its unmatched stretches.
2. `Future<List<OverlayWay>> unvisitedIn(southWest, northEast,
   corridorsByWay)` — same tile enumeration, floor 3 (`overlayMaxTiles`
   constructor param), per-bucket decode via `bucketByKey`, per way:
   skip geometry shorter than 2 points; use `unvisitedStretches`; skip
   ways yielding no stretches. Memoized by the same rectangle + epoch
   discipline (cleared by `invalidate()`).
3. Report/overlay passes stay independent: the chip answers at wider
   views; the overlay just abstains there.

### `lib/ui/app_model.dart`

1. `_viewportOverlay` state + getter; computed in the same
   `_recomputeViewportCoverage` flow after the report (overlay skipped
   when its own floor says so). Same staleness guard and notify.
2. `mergedCorridors()` iterates visible tracks only.

### `lib/ui/map_page.dart` + `lib/ui/road_coverage_chip.dart` area

1. `_buildUnvisitedPolylines()` — model overlay state to Polyline list
   (dashed, blue-grey `withValues(alpha: 0.55)`, strokeWidth 3).
2. Layer inserted directly after `TileLayer`, before the fog
   `CircleLayer`; rebuild rides the existing model listener — no new
   timer, no new event plumbing.

### Tests

1. `test/way_geometry_test.dart` — merge order/overlap, cut
   interpolation, projection tolerance (nearest under drift), and
   `unvisitedStretches`: disjoint visits leave the gap unlit; a full
   corridor empties the way; a single mid-way corridor leaves two
   stretches; stale-geometry corridor still maps within tolerance.
2. `test/road_coverage_test.dart` (extended) — overlay: no corridors →
   all four fixture ways drawn fully; full corridor on Main Street →
   Main absent; floor 3×3 → empty list; unchanged viewport memoizes
   (second call re-decodes nothing new vs store counters).
3. `test/app_model_test.dart` (extended) — overlay state on settle
   (fixture: fewer ways than total), hidden track returns its ways to
   the overlay and to the chip's ratio, absent below floor.
4. `test/map_page_test.dart` (extended) — region-gated: no region →
   no dashed layer; with region and settle → dashed polylines present,
   under the corridor layer; below the overlay floor → absent.

## Out of scope

- Any persistence or format change (stretches are derived, not stored).
- Settings toggle for the layer (density is already zoom-gated).
- Filtering by road class (drawing `highway=footway` in a city block is
  the point of "unvisited"; class filters can come later if noisy).
- Android frame-rate tuning beyond the floor: manual desktop check
  watches it, and the floor constant is the tuning knob.

## Verification

`flutter analyze` clean; `flutter test` green; manual desktop sanity
with the Sardinia region — pan into a Cagliari neighborhood, expect
dashed grey roads with the walked corridors painted on top and the
chip's share matching what is visibly dark; zoom out past the floor and
confirm the dashed layer disappears while the chip keeps its answer.
Commit the slice with this plan file and remove the TODO.md unit, which
completes the backlog item.
