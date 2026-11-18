Implements: TODO.md #1

# Viewport road-coverage chip (unit 1 of "Show unvisited roads")

## Problem

With a road region active, the app reveals which roads have been walked
(corridors) but gives no quantitative answer to the question the app's
name asks: how much of the road network around here is still unvisited?
The screen shows what is unlocked; the complement — unvisited roads,
the next place to go — is only visible by absence.

The final objective (TODO.md-item) is to draw unvisited roads in the
current view. This first slice builds the aggregation machinery that
goal needs — per-way matched-vs-total length over the viewport's buckets —
and surfaces it as a length-weighted "unvisited share of roads in view"
chip. Slice 2 (overlay) will reuse the same pass to draw unmatched
geometry instead of reducing it to a number.

## Design decisions

- **Length-weighted, not way-counted.** A 40 km SS131 counts more than
  two 50 m footways. The number is: `1 − Σ(matchedᵢ) / Σ(totalᵢ)` over
  the ways whose bucket intersects the viewport; matchedᵢ is capped at
  totalᵢ per way.
- **Matched per way comes from stored corridors, no re-matching.**
  `StoredTrack.unlockedWays` already persists the corridor polylines;
  their point-to-point lengths sum to the covered span (corridor cuts
  are interpolated at meter offsets on the way's own geometry).
  Corridors from overlapping visits may double-count shared stretches —
  matched is summed across tracks and **capped at the way's total**, a
  bounded over-count consistent with the matcher's existing cosmetic
  tolerance for parallel over-unlocking. Honest interval-union across
  tracks needs interval data the format does not store; not worth a
  format change for a chip.
- **Denominator per bucket, decoded once per session per bucket.** An
  LRU (16 entries) on the `RoadStore` instance maps bucket key →
  {wayId → totalMeters}. Scalars only — geometry is never retained,
  so the worst case is kilobytes per bucket, tens of MB of maps for a
  whole-region FLING through all buckets.
- **Coarse signals, cheap recompute.** Recompute is debounced (300 ms)
  and keyed off the viewport's z12-tile rectangle: if the rectangle is
  unchanged since the last pass, skip (follow-cam 1 Hz re-centers and
  zoom-in flights recompute once the rectangle actually changes).
  Buckets already in the LRU cost nothing; a walk around one town
  touches a handful of distinct buckets all session.
- **Zoom floor.** When the viewport spans more than ~6×6 z12 tiles the
  chip stops recomputing and greys out; a whole-Sardinia view would
  decode all 515 buckets (37 MB, seconds on Android — the bench in
  ARCHITECTURE.md prices bucket decode). The floor keeps the chip a
  local-zoom feature; unit 2 (drawing unvisited roads) has the same
  floor, for the same reason.
- **Display framing: the chip shows the unvisited share** ("Roads not
  yet explored here: 57%") — the complement reads as the next place to
  go, the app's whole narrative; "you have unlocked 43%" reads as a
  score. Same number, user-facing as unvisited.
- **Region-gated.** No road region → no chip. The denominator exists
  only inside the active `RoadStore`; corridors without a region keep
  rendering (existing behavior) but say nothing quantitative about
  the network.

## Changes

### `lib/road/road_coverage.dart` (new, pure Dart)

1. `ViewportCoverage`, constructed on the active `RoadStore`:
   - `Future<CoverageReport?> coverage(LatLngBounds bounds)` — null when
     the bounds' z12-tile rectangle exceeds the floor (6×6) or covers
     no known bucket.
   - Deep copy of inputs on entry (corridor lists passed in), pure
     data out. Yields between buckets (`Future.delayed(Duration.zero)`,
     the `_rematchAllTracks` pattern) so the UI stays live.
2. `CoverageReport`: `totalMeters`, `matchedMeters`, ways counted;
   `unvisitedRatio` getter (0 when total is 0 — a view with no roads
   under it reports nothing rather than "100% unvisited").
3. Per-bucket total-length LRU (16 entries) keyed on bucket key, values
   are `Map<String, double>` way totals; a second-level memo of the last
   report keyed by tile-rectangle string.
4. Matched side: for each way id present in both the viewport's buckets
   and the supplied corridors, sums capped at the way total; corridor
   polylines from an old region whose ids are absent from the current
   buckets are ignored (they contribute nothing to either sum).

### `lib/ui/app_model.dart`

1. Holds a `ViewportCoverage?` alongside `_roadMatcher` — created on
   `setRoadFile`, dropped on deactivate.
2. `void viewportSettled(LatLngBounds bounds)`: debounce timer (300 ms),
   then async `coverage()`; result (or null) stored in a field behind a
   getter, `notifyListeners()` on change only.
3. Clear coverage state on region swap/removal; the tile-rectangle memo
   lives inside the coverage object, so a swap naturally resets it.

### `lib/ui/map_page.dart`

1. In the existing `_mapEvents` listener, on end-type events
   (`MapEventMoveEnd`, `MapEventFlingAnimationEnd`, `MapEventRotateEnd`,
   `MapEventDoubleTapZoomEnd` — flutter_map 8.3.2 classes) call
   `widget.model.viewportSettled(_mapController.camera.visibleBounds)`.
2. Same call after the programmatic `move()` sites (initial fit,
   follow-cam re-center, back-to-shortcut) — controller moves don't
   emit gesture end events.
3. `CoverageChip` widget (new file in `lib/ui/` or map-local):
   listens to the model; hidden when no region or report is null;
   greyed-out placeholder when out of zoom floor; styled like the
   existing HUD corner chips. Only the chip text needs the model.
4. Chip goes bottom-left, mirroring the zoom slider's left edge
   without overlapping it.

### `lib/l10n` (AppStrings + English + Italian)

- `roadsUnvisitedInViewLabel` — "Roads not yet explored here" /
  "Strade non ancora esplorate qui".

### `test/road_coverage_test.dart` (new)

Against the synthetic fixture (`test_roads.unvisited-roads`, Berlin
streets) plus hand-built corridor inputs:

1. One corridor covering half of one fixture street, bounds spanning
   that tile: report ≈ 50% unvisited (tolerance for interpolation).
2. Two tracks with disjoint corridors on the same way: sums; same
   stretch walked twice: capped at total, never > total.
3. Ways with no corridors count fully in the denominator; a view
   covering no road buckets reports null/0-ratio distinctly.
4. Zoom floor: bounds of 7×6 tiles → null.
5. Corridor ids absent from the store's buckets → ignored, both sums.
6. LRU behavior: second identical query decodes no new buckets
   (`parsedBucketCount` stalls).

### `test/app_model_test.dart` / widget test on the chip

- Chip hidden without region, visible with; text shows the label and
  the percentage format.

## Out of scope

- Drawing unvisited geometry (unit 2 — the overlay).
- Cross-track interval-union fixture honesty, or a format change to
  store intervals rather than polylines.
- Isolate/off-thread compute; per-bucket disk cache; city LOD.
- Any change to matching, persistence format, or the region pipeline.

## Verification

`flutter analyze` clean; `flutter test` green; manual desktop check
with the Sardinia region (pan around Cagliari at street zoom, watch the
chip recompute; zoom the whole island in, expect the greyed-out floor);
commit the slice with this plan file and remove the TODO.md unit entry.
