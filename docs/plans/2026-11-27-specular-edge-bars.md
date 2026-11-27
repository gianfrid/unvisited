# Specular edge bars: record cluster mirrors the control pill

Implements: —

## Problem

While recording, the camera/stop/pause bar ([RecordCluster]) is not the
mirror image of the zoom/locate/rotation bar ([MapControlPill]) on the
opposite edge: the two are anchored differently and their vertical
centers differ. Two concrete causes in `lib/ui/map_page.dart` /
`lib/ui/map_controls.dart`:

1. Different SafeArea top insets per bar. Both bars are
   `Positioned(top: 0, bottom: 0)` + `SafeArea(minimum: …)` + `Center`,
   but the pill gets `top: zoomSliderSide == 'left' ? 16 : kToolbarHeight + 24`
   while the cluster gets the swapped
   `top: zoomSliderSide == 'left' ? kToolbarHeight + 24 : 16`.
   The bar on the side with the larger inset is centered
   `(kToolbarHeight + 24 − 16) / 2 = 32 px` lower — so while recording
   the cluster hangs lower than the pill instead of facing it level.
2. Different vertical padding: the pill's container pads
   `EdgeInsets.symmetric(vertical: 4, horizontal: 4)`, the cluster's
   only `EdgeInsets.symmetric(horizontal: 4)` — the cluster is 8 px
   shorter, breaking the mirror in size as well as position.

## Plan

1. `lib/ui/map_page.dart`: give both edge `Positioned` wrappers the same
   SafeArea minimum regardless of side —
   `EdgeInsets.only(top: kToolbarHeight + 24, bottom: 16)` — so both bars
   center in the identical band between toolbar and bottom inset. (The
   centered top toolbar can reach either edge on narrow screens, so
   clearing the toolbar band on both sides is also the overlap-safe
   choice; the stale comment claiming the left side never meets the
   toolbar gets corrected.)
2. `lib/ui/map_controls.dart`: change the `RecordCluster` inner padding
   to `EdgeInsets.symmetric(vertical: 4, horizontal: 4)`, matching the
   pill's container exactly.
3. Update the doc comments on both bars that describe the anchoring, so
   they say "vertically centered in the same band as its mirror" rather
   than the side-dependent insets.
4. Verify: `flutter analyze` clean, `flutter test` passes (existing tests
   assert only the pill/cluster edge `left`/`right` values and bottom
   clearances, none of which change).

No SPEC.md change: the spec says the cluster mirrors to the opposite
edge; this restores that intent. No new strings, no new packages.
