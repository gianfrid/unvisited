Implements: TODO.md #overlap-1, #overlap-2, #overlap-3

# Overlap dedup: never render a point another track already covers

## Problem

With many tracks the map slows down badly. The cause is duplicate
geometry: the fog overlay dedups points *within* one aggregate (the
`unlockCenters` grid) but nowhere else.

- `AggregateTrack.points` concatenates every member's points, and the
  polyline/ink styles draw **every member's** segments: N rides over the
  same ground paint it N times (×3 ink passes × strips). The selection
  highlight overdraws itself the same way.
- Circles: the same grid cell is drawn once per aggregate that touches
  it — cross-aggregate overlap is never deduped.
- Member-picking mode is the heaviest: `laneOffsetsPerVertex` runs over
  *all* member points on every half-zoom step (grid build + 3×3 cell
  scan with haversine per point), and every member's full geometry is
  drawn as a spread lane, overlapping or not.

flutter_map's culling and simplification are already in place (its docs
themselves warn "excessive use of circles may create performance
issues"); what is left to remove is the duplicate geometry itself.

## Research (overlap-1): approaches surveyed

| Approach | Verdict |
|---|---|
| Shared per-band occupancy grid — skip any point whose cell an earlier track already claimed; break polylines at dropped runs | **Chosen** (normal mode) |
| Click-local reveal — spread lanes only for the tracks passing a tapped point, within a window | **Chosen** (member picking) |
| Offscreen raster fog canvas (`ui.Image` per band+viewport) | Rejected: kills overdraw completely but a large change, zoom/pan invalidation complexity, blur at fractional zooms |
| Import-time point decimation | Rejected: mutates stored data and dedup semantics; fidelity is cheap to keep at render time |
| More flutter_map knobs (`polylineCulling`, simplification tolerances) | Already on; nothing left there |
| Clustering/LOD per zoom band | Already exists (`fogCellSizeFor` doublings, `decimate`); orthogonal — keeps cost bounded by area, not by duplicate count |

The occupancy grid reuses the exact cell math of `unlockCenters` (cell
edge = fog band, longitude cells widened by the 45° cosine) so the
union is preserved by construction: a skipped point's neighborhood is
already painted by the claiming track — the same argument that makes
neighboring unlock circles a continuous corridor.

One finding from implementation: at the base band (12 m cells) two
*separate* aggregates can never share a cell — any two points within a
cell's ~17 m diagonal are far inside the 100 m union-find threshold and
would already be one aggregate. Cross-aggregate claims only collide at
coarse zoom bands (cell edge ≥ ~96 m) or with a lowered aggregate
threshold. The dominant duplicate-geometry cost is *member* overlap
inside one aggregate (the polyline/ink styles drew every member's
points); that is what the widget tests pin.

## Decisions

- **Claim order is stable and deterministic**: aggregates in model
  order, members in aggregate order; the *first* track through a cell
  wins its tint (today the last-painted covers — a slight, accepted
  visual shift in shared cells).
- **The selection highlight dedups only across its own members**, never
  across aggregates: the highlight's job is to show the selected
  extent over other aggregates' fog.
- **Member picking, before any tap** (asked): members draw as *plain
  single lines* on their true geometry — no lane spreading, no offset
  math. Hidden members keep their dashed ghosts; coincident visible
  members read as one line (indistinguishable anyway).
- **Reveal on tap** (asked): tapping a point where several members pass
  (within the existing ~24 px picking tolerance) reveals those members
  as spread lanes within a **±500 m window** along each involved
  track around the tap; a repeat tap cycles the pick (current
  behavior kept). A single-member point picks directly, as today.
- The reveal rides the existing `laneOffsetsPerVertex` math restricted
  to the window's points — O(window), not O(catalog).

## Slice 1 — normal mode (completes overlap-2)

### `lib/ui/fog_of_war.dart` (pure Dart, no Flutter imports)

1. `claimUnlockCenters(points, cellSize, seen)`: like `unlockCenters`
   but takes the shared `seen` map and claims into it — a point whose
   cell is already claimed is skipped. `unlockCenters` delegates to it.
2. `dedupeSegments(segments, cellSize, seen)`: per segment, a point
   entering a cell another point already claimed ends the run (kept as
   the one-point handoff so a resuming line stays continuous with the
   claiming track's), and the next unclaimed cell starts a run that
   reaches one point back. Interior points of a cell the run itself
   owns are kept as-is — without this, normal GPS density (points every
   couple of meters in 12 m cells) would shred a track into stubs.
   A fully covered segment drops out; trailing runs need two points.
   Returns sub-segments; cell math identical to `claimUnlockCenters`.

### `lib/ui/map_page.dart`

3. `_buildFogCircles`: one shared `seen` across all aggregates, in
   model order; each aggregate's centers come from
   `claimUnlockCenters`. The per-aggregate `_fogCentersByAnchor` cache
   is replaced by memoizing the whole built `CircleLayer` widget under
   a global key (style + band + every aggregate's members + tints) —
   the `_fogLineLayer` pattern extended to circles, since claims make
   per-aggregate caches order-dependent.
4. `_buildFogLines`: polyline segments and ink strokes are computed
   from `dedupeSegments` output (per aggregate, same shared `seen`);
   strip budget and pass widths unchanged. The `_inkPassesCache` /
   `_fogLineLayer` caches move under the same global key.
5. `_selectionHighlightLayers`: same member-level dedup within the
   selected aggregate (own `seen`), in all three styles.
6. Corridors are already deduped by way id — untouched.

### Tests

- `test/fog_of_war_test.dart`: claim/dedupe helpers — union preserved,
   claim order respected, segment splitting with handoffs at covered
   runs, interior smoothness, out-and-back revisits drawn once, empty
   output for fully covered segments, kept points claiming for later
   segments.
- `test/map_page_test.dart`: a synthetic 150-point corridor imported
   twice (one aggregate, two members): polyline-style fog lines
   identical to a single-member catalog; circle count unchanged (the
   per-aggregate coalescing regression guard); the polyline-style
   selection highlight dedups its own members (150 shared points, not
   300). Existing ink assertions kept (strokes now from deduped runs).

### Verification

- `flutter analyze` clean; `flutter test` green.
- Manual perf check on desktop: a synthetic catalog of ~20 overlapping
  tracks (small per-file perturbations so the dedup rules don't eat
  them) — frame time while panning at a fixed band, plus a before/after
  count of built circles/polylines (temporary counters, not committed).
  Visual union must be unchanged vs the same view pre-change.

## Slice 2 — member picking (completes overlap-3)

### `lib/ui/map_page.dart`

1. `_memberLanes()` is replaced by cheap *plain* member lines:
   decimated, segment-split, no lane offsets, no overlap grid —
   drawn (with ghosts/glow) by `_memberPickLayers` exactly as today's
   lanes are. Reuses slice 1's deduped segments among visible members;
   ghosts stay separate.
2. Tap flow in `_pickMemberAtTap`: on >1 candidate within tolerance,
   compute for each candidate member the ±500 m window around its
   nearest point to the tap (pure helper), spread those window points
   with `laneOffsetsPerVertex` (only window points in
   `membersPoints`), and draw them as the revealed lanes; the reveal
   state (tap position + involved members) lives in page state, cleared
   on exit/deselect/membership change. Repeat taps cycle through the
   candidates as today; single-candidate points pick immediately.
3. Desktop hover glow applies only to revealed lanes.
4. The pick tolerance, cycling threshold and bubble anchoring are
   untouched.

### Pure helper + tests

- Window extraction (nearest point to tap, ±500 m along the member's
  points) goes next to `lane_offset.dart`'s pure math, unit-tested
  there (`test/lane_offset_test.dart`): window bounds, wrap at segment
  ends, single-point members.
- `test/map_page_test.dart`: plain lines before any tap (no spread);
  reveal draws only the involved members' windows; repeat-tap cycles;
  ghost members excluded from reveal; reveal cleared on exit.
- `lib/l10n/app_strings.dart`: `memberPickToast` re-worded if it no
  longer matches (English + Italian; the untranslated-string test
  enforces both).

### Verification

- `flutter analyze` clean; `flutter test` green.
- Manual: enter picking on a many-member aggregate — no spread cost,
  tap a multi-track point → only those lanes appear near the tap, cycle
  picks, bubble actions unchanged.

## Commit plan

- Slice 1 commits with this plan file; the commit removes `overlap-1`
  and `overlap-2` from TODO.md.
- Slice 2 commits after slice 1 is green; its commit removes
  `overlap-3`, leaving the tree clean.

## Out of scope

- Rasterized fog canvas (revisit only if the grid dedup proves
  insufficient at catalog scale).
- Any change to aggregation thresholds, fog banding, or the ink strip
  budget.
- Changing how single-track selection/highlight works outside member
  picking.
