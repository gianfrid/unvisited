Implements: TODO.md #1

# Clip the road coverage passes to the visible viewport

## Problem

The chip and overlay enumerate z12 *buckets* - the region file's only
spatial index - so their "current view" is really "the ~7x7 km tile the
camera falls in". Zooming onto a walked corridor leaves the unvisited
share high, because every road in the whole tile (often ~5,000 ways)
still counts in the denominator while the walked street subtracts only
its own meters. The drawing layer hides this (flutter_map culls
off-screen polylines), so the map says "visited" while the number says
"~85% not" - the two answer different questions.

## Decision

Both passes keep the bucket enumeration (the file's only index, and
decoding whole buckets stays the right granularity for the LRU), then
clip at way granularity: a way whose bounding box does not intersect
the camera's lat/lon rectangle contributes to neither the chip nor the
overlay. This makes the chip mean "the roads on my screen" and
restores agreement with the dashed layer by construction - same way
set, same clip, both sides. A partially visible way (bbox clipped by
the screen edge) still counts - the conservative bbox rule the bucket
registration itself already uses (build_roads registers a way in every
bucket its bbox touches).

## Changes

### `lib/road/road_coverage.dart`

1. The scalar bucket cache grows the way bbox: `_bucketTotals` maps
   bucket key to way-id to `(lengthMeters, minLat, maxLat, minLon,
   maxLon)`. Still scalars only - decoded geometry is never retained;
   the LRU bound (64 buckets) is unchanged.
2. `_decodeTotals` accumulates min/max in the same single walk that
   sums segment lengths - one pass over each bucket, no extra decode.
3. A private `_intersectsViewport(wayBox, southWest, northEast)`
   predicate: false only when the way's bbox lies fully outside the
   lat/lon rectangle (one comparison per axis, no margin).
4. `coverage()`: skip non-intersecting ways when building `wayTotals`
   - they add to neither sum nor `wayCount`.
5. `unvisitedIn()`: same filter - compute the bbox from the decoded
   points in the existing per-way loop (the store's bucket LRU already
   paid the decode; the min/max walk is linear and memoized per
   rectangle, so it rides the existing settle cadence).
6. Chip and overlay floors stay as they are (6x6 and 3x3); clipping
   makes zooming *in* accurate, and the wide-view floors still guard the
   decode-all cost.

### Semantics notes

- A view whose bucket exists but whose roads all fall outside the
  bounds now reports null (nothing on screen) rather than the tile's
  share - a truthfulness improvement the tests pin.
- Corridor capping, length weighting, memoization and the epoch walk
  are untouched - this slice only narrows which ways enter the sums.

## Tests (`test/road_coverage_test.dart` extended)

1. All four fixture streets remain counted in the wide block view
   (their bboxes all intersect) - existing expectations unchanged.
2. A tight viewport at the tile's far corner (northern tip of nothing
   - the Berlin fixture's Cross Avenue excluded by lon, Main/Parallel/
   Service by lat) reports null: on-screen roads only.
3. The overlay lists exactly the bbox-intersecting ways: a mid-view
   rectangle that cuts two of the four streets out leaves them out of
   the dashed data while the wide view still draws all.
4. A partially visible way (bbox straddling the screen edge) still
   counts - conservatism preserved.
5. Model wiring: the fixture-based settle tests keep passing
   unchanged (their bounds contain all streets).

## Out of scope

- Way bbox persistence into the road file format (runtime compute is
  cheap and the format stays frozen).
- Screen-edge sampling tighter than bboxes (sub-meter accuracy at the
  frame edge is not worth the geometry math per settle).
- Changing the floors or the drawing style.

## Verification

`flutter analyze` clean; `flutter test` green; desktop sanity with the
Sardinia region: zoom close to a fully walked street - the unvisited
share should collapse toward 0%, and zooming back out to the 3x3-tile
band the chip and dashes should keep telling the same story. Commit
the slice with this plan file and remove the TODO entry.
