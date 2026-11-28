# Overlay freshness: the memo must cover what it serves

Implements: —

## Problem (user report)

"The glow doesn't apply immediately — in some roads only after zooming and
panning around."

Both viewport passes in `ViewportCoverage` (`lib/road/road_coverage.dart`)
memoize on the **z12 tile rectangle** (plus the corridor version) but clip the
ways against the **exact screen corners of whichever viewport computed the
answer first**:

- `unvisitedIn` — memo key `_lastOverlayRectangle`; inline bbox clip against
  the computing pass's exact `southWest`/`northEast`.
- `coverage` — memo key `_lastRectangle`; `_intersects` against the same.

A later viewport inside the same tile rectangle (any sub-tile pan, a small
zoom) gets a memo hit and therefore an answer clipped for the *old* view:
roads that just entered the screen are missing from the overlay (and the
chip's share answers the old view too) until a bigger move changes the tile
rectangle. With the dashes this was barely visible; the wider glow makes the
missing edge roads obvious.

## Fix — make each memo's hit condition match its clip

The memo may only be served when the stored answer provably covers the
incoming view:

1. `unvisitedIn` (the geometry pass — must keep its follow-camera skip):
   clip against the view **expanded by a 25% margin per axis**; store the
   expanded rectangle; a memo hit additionally requires the incoming view to
   be **contained** in the stored rectangle. A re-center or small pan stays
   inside the margin and skips (the design's skip survives); a pan beyond it
   recomputes with the new view. Off-margin list entries are invisible
   (flutter_map culls off-screen polylines), so widening the clip costs a
   little compute only, and what's on screen is always fully covered.
2. `coverage` (the chip — cheap, scalar, and the spec pins "the number
   agrees with what is on screen"): memo hits only when the corners are
   **exactly** the stored ones (duplicate settles — rotation taps, camera
   settles that moved nothing — still skip; any real movement recomputes the
   scalar walk). Containment is not enough here: a contained *smaller* view
   would be answered with the larger view's share.

`invalidate()` clears the stored rectangles along with the memos; the
null-floor branch clears them too.

## Tests (written first, both fail today)

`test/road_coverage_test.dart`, fixture views chosen inside one z12 tile
(premise asserted via `roadBucketKeyFor` on every corner):

1. Chip: view A (corners exclude Main Street + Service Road, wayCount 2),
   then view B in the same tiles that includes them → `wayCount` must become
   4 (today: memo serves A's report, 2).
2. Overlay: same A → B; B's list must contain all four ways (today: A's
   clipped {1002, 1003}).
3. Overlay skip preserved: a ~2% recenter within the stored margin returns
   the identical list instance.
4. Chip skip preserved: an identical repeat call returns the identical
   report instance.
5. Overlay zoom-in (contained in the margin) returns the identical instance.

`test/app_model_test.dart`: end-to-end settle-settle — `viewportSettled(A)`
then `viewportSettled(B)` (same tiles, B wider) must produce an overlay that
contains the ways only B can see.

## Steps

1. The tests above (failing).
2. `road_coverage.dart`: the two memo hit conditions, the stored
   covered/last rectangles, the `_expanded`/containment helpers; doc
   comments on both passes.
3. `ARCHITECTURE.md` (§ Road matching): the memo sentence — "memoizes on
   the viewport's exact tile rectangle plus an unlock epoch, so follow-
   camera re-centers at an unchanged rectangle skip all work" — now
   describes the covered-rectangle rule for the overlay and the exact-corner
   rule for the chip.
4. `TODO.md`: one backlog entry for a separate, adjacent race found while
   reading the recompute path (stale-corridor recomputes can land out of
   order after a catalog change) — not fixed in this slice.
5. `flutter analyze` clean, `flutter test` passes; commit.

## Out of scope

- The startup overlay floor (a fit-to-all-tracks city view legitimately
  draws no glow; zooming in past 3×3 z12 tiles lights it) — by design.
- The out-of-order recompute race (goes to the backlog).
- Any change to matching, persistence, or the glow styling itself.
