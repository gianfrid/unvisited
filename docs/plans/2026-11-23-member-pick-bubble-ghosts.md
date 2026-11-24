# Member-picking v2: anchored action bubble, ghost lines, lane offsets

Implements: —

Supersedes the member-picking UX shipped in cbfdcd1 (plan:
2026-11-23-selection-bar-member-map-picker.md). The colored-tracks-on-the-map
idea stays; the interaction around it is redesigned:

- **Bubble at the tap point**: picking a track shows a floating callout
  anchored on the map next to the picked track — its name in its assigned
  tint plus two labeled buttons, "Hide this track" / "Hide the others" (no
  more action row in the bottom bar; no more icon-only buttons).
- **Ghost lines**: hidden members stay drawn in picking mode as dashed,
  translucent grey lines; tapping a ghost shows a bubble with one action,
  "Show this track". Hiding is reversible in place; "Hide the others" is
  no longer a one-way door.
- **Overlapping tracks** (cumulatively the major concern): every member —
  colored or ghost — renders as one parallel lane with a small constant
  perpendicular offset (lane k = k × ~3 screen px at the current zoom half
  step, like the ink strokes' ground-meters→px conversion), so coincident
  geometry reads as side-by-side colored lines with their own hover/tap
  space. Hit-tests run against the same offset polylines the renderer
  draws (aimed = hits). Where two lanes still converge (crossings), a
  repeated tap within a short window cycles to the next candidate when
  the top two are within ~4 px. The bubble identifies the pick by name +
  color, so a mis-pick is instantly visible and cheap to undo.
- **Tap-away exits the mode**: a tap that misses every lane clears the
  pick AND exits picking back to normal selection.
- **Mode guidance**: entering picking shows the map toast ("Tap a track
  to pick it") and auto-fits to the selection's bounds when members fall
  outside the viewport; the tracks button reads active.
- **Desktop hover** (`MouseRegion` in picking mode): hovering offsets a
  temporary glow to the hovered lane's track so aiming is a two-stage
  interaction; no-op on touch.

Out of this round: a long-press/right-click hide shortcut (deferred).

## Steps

1. `lib/aggregate/member_colors.dart` — keep `assignMemberTintKeys` as is;
   add lane ordering: the deterministic greedy order already produces a
   member sequence; export it (e.g. return the ordered ids, or a
   `Map<String, (String tint, int lane)>`) so the page renders lane k for
   member k without re-deriving order.
2. `lib/ui/map_page.dart`:
   - A new pure helper `_offsetLanePoints(List<LatLng>, int lane)` (or in a
     small module, unit-testable): each decimated segment's points pushed
     perpendicular to the local segment direction by `lane *
     _lanePx() * groundResolution`, recomputed per zoom half-step like
     `_pxPerMeter`. Segments shorter than a screen px keep the raw point.
   - `_memberPickLayers()`: draws colored lanes (stroke 4, alpha 0.9),
     ghost lanes for hidden members (dashed, grey, alpha ~0.5, width 3,
     drawn first), and the picked track's glow (wide translucent halo +
     solid bordered line, at its lane).
   - Hit-testing refactor: `_pickMemberAt(LatLng tap)` returns candidates
     by exact offset-lane screen distance (via `MapCamera` pixel math on
     the same offset code path), not raw haversine on track points.
   - The bubble: a positioned overlay in the page's `Stack`, screen point
     from `camera.latLngToScreenOffset(pickedPoint)` plus a small leader
     offset, clamped to the map's bounds. Contains: color dot + track name,
     one button per context (hide / hide-others for colored; show for
     ghost), auto-dismissed on model change to pick/exit. Keep it inside
     the safe area near the screen edges.
   - `onTapUp` in picking mode: hit-test lanes → pick + (if a cycle tie)
     remember the tap spot and candidate list; a near-identical spot
     within a short window promotes the next candidate; miss →
     `model.exitMemberPicking()`.
   - `MouseRegion` (pointer devices only): hover re-runs the lane hit-test
     and drives the same glow visuals without a pick (`hoveredMemberId`,
     page-local state).
   - Entering picking: toast via the existing `_toast`, and (only if the
     selection's bounds are not fully inside the camera) the existing
     `_fitWhenSized(CameraFit.coordinates(...))`.
3. `lib/ui/app_model.dart`:
   - Trim to picking state: `memberPicking`, `pickedMemberId`,
     `selectedMemberIds`, `memberTintKeys` (+ lane order) — remove
     bar-side row remnants (`showOnlyPickedMember`/`hidePickedMember`
     bodies stay as the bubble's actions; `pickMemberAt` moves to exact
     lane-screen-space candidates supplied by the page, so the model
     method takes the resolved id list instead of doing its own scan).
   - `exitMemberPicking()`: clears pick + mode, notifies (tap-away and
     the tracks button both use it).
   - Re-anchor/color migration on hide unchanged.
4. `lib/ui/map_actions.dart` — the bar's second row is removed (bubble
   owns the actions); the tracks button keeps toggling mode and gets the
   active styling.
5. `lib/l10n/app_strings.dart` — labeled bubble buttons (en / it):
   `memberPickHide` 'Hide this track' / 'Nascondi questa traccia',
   `memberPickHideOthers` 'Hide the others' / 'Nascondi le altre',
   `memberPickShow` 'Show this track' / 'Mostra questa traccia',
   `memberPickToast` 'Tap a track to pick it' / 'Tocca una traccia per
   sceglierla'. `trackShowOnlyTooltip` becomes unused and is removed
   (unused strings must not survive: keep the `allStrings` pins in
   sync).
6. Tests:
   - Lane math: helper unit tests — perpendicular offset sign/size, lane
     spacing, degenerate short segments.
   - AppModel: exitMemberPicking semantics + existing hide/show-only
     behaviors still covered; cycle candidates come from the page, so
     model tests here stay on id-list resolution.
   - `test/map_page_test.dart`: rewrite the picking widget test — tracks
   button → lanes render + toast; tap at a lane picks (bubble appears with
   the name and colored dot); hide-this turns it into a ghost; tap ghost →
   bubble shows Show → restores; hide-others leaves one colored lane and
   the rest ghosts; overlap: two coincident tracks render distinct lanes
   and each is tappable separately; tap-away exits picking; repeat-tap at
     a crossing cycles the pick.
7. Verify: `flutter analyze` clean, `flutter test` passes; commit the plan
   with the change.

## Notes

- Offsets and hover exist only inside picking mode, one aggregate's worth
  of points: per-frame cost stays trivial; recomputes ride the existing
  zoom-half-step banding.
- Ghosts draw only in picking mode (visually honest everywhere else: a
  hidden track is gone from the map proper).
- The bubble is a presentation overlay only; all actions go through the
  existing model methods.
