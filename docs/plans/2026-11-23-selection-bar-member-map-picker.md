# Selection bar: pick member tracks on the map, each in its own color

Implements: —

Revision of `2026-11-23-selection-bar-member-strip.md` (committed as
ecdafae): the user found the horizontal chip strip not scrollable on
desktop. New flow, per the user's spec:

1. Select a multitrack (map tap) → selection bar.
2. Press the tracks button on the bar → **member-picking mode**: every
   member track of the selected aggregate is drawn directly on the map as
   its own polyline in its own color (repetitions allowed, but never the
   same color for two *near* tracks).
3. Tap a track on the map → it **glows** and the bar shows that track's
   actions: **hide this track**, or **show only this one** (hide the
   others).

The horizontal strip from ecdafae is removed; `selectedMemberIds` stays
(it drives picking and the action row).

## Steps

1. `lib/aggregate/member_colors.dart` (new, pure Dart, unit-testable):
   `assignMemberTintKeys(List<AggregateInput> members, {double nearMeters,
   List<String> palette})` → `Map<String, String>` trackId → tint key.
   Adjacency = any point pair within `nearMeters` (default 30 m), found
   with the same grid-bucketed neighbor scan the union-find uses, so cost
   is O(points) per area, not O(n²). Greedy coloring ordered by descending
   degree (ties by id, so it is deterministic) over the 8-key
   `explorationTints` palette; neighbors always differ while the palette
   lasts, non-adjacent tracks may repeat.
2. `lib/ui/app_model.dart`:
   - `bool memberPicking` + `String? pickedMemberId`, both cleared by
     `clearSelection()`, `hideSelectedAggregate()`, and the
     `selectedAggregate` gone-fallback. `toggleMemberPicking()` requires
     an active selection.
   - Memoized `memberTintKeys` for the current selection (cached on the
     member-id list, like `aggregates`).
   - `String? mapTap(LatLng tap, {required double toleranceMeters})`:
     routes map taps — in picking mode, `pickMemberAt` (nearest visible
     member track with a point within the tolerance wins; a miss clears
     the pick); otherwise the existing `selectAggregateAt`.
   - `Future<void> hidePickedMember()` → `setSelectedMemberVisible(picked,
     false)`, then clear the pick.
   - `Future<void> showOnlyPickedMember()` → hide every other visible
     member; re-anchor + color migration when the anchor was hidden —
     refactor the re-anchor block out of `setSelectedMemberVisible` into a
     shared helper both call.
3. `lib/ui/map_page.dart`:
   - `_onMapTap` calls `model.mapTap(...)` instead of
     `selectAggregateAt(...)` directly.
   - New layer where the selection highlight is: in picking mode, one
     decimated, segment-split polyline per visible member in its assigned
     full-opacity tint (strokeWidth 4), and the picked track gets a glow —
     a wide translucent under-stroke plus the solid line. The aggregate
     highlight is suppressed in picking mode (the colored tracks replace
     it); fog circles/corridors are untouched.
4. `lib/ui/map_actions.dart` — `SelectionBar` back to a single actions
   row (strip removed): hide-all / color / fit / **tracks toggle** /
   dismiss. The tracks button toggles `memberPicking` and reads as active
   while on. When `pickedMemberId` is set, a second row shows the picked
   track's name plus two icon buttons: hide it (`Icons.visibility_off`,
   `trackHideTooltip`) and show-only (`Icons.filter_1`,
   `trackShowOnlyTooltip`).
5. `lib/l10n/app_strings.dart` — add `trackShowOnlyTooltip`
   ("Show only this track" / "Mostra solo questa traccia"); keep
   `selectionTracksTooltip`, `trackHideTooltip`, `trackShowTooltip`.
6. Tests:
   - `test/member_colors_test.dart` (or the aggregate test file): near
     tracks get different keys, non-adjacent may share, deterministic,
     palette keys only.
   - `test/app_model_test.dart`: picking-mode lifecycle; `mapTap` picks the
     nearest member within tolerance and clears on a miss; hide-picked;
     show-only-picked (incl. anchor/color migration); mode cleared by
     hide-all and dismiss.
   - `test/map_page_test.dart`: tracks button enters picking and the
     member polylines render; a map tap on one track glows it and shows
     the picked row; hide-this hides it; show-only hides the others.
   - `test/app_strings_test.dart`: pin `trackShowOnlyTooltip`.
7. Verify: `flutter analyze` clean, `flutter test` passes. Commit the new
   plan file with the change.

## Notes

- Picking hit-test scans member points per tap (O(points), same order as
  the existing aggregate tap scan).
- Member polylines draw in every fog style — the mode is temporary and
  always reads as plain colored lines.
- Hiding the picked track clears the pick; hiding the last visible member
  drops the selection as before.
