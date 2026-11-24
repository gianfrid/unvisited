# Selection bar: hide single tracks of the selected multitrack

Implements: —

Design approved by the user on 2026-11-23 (option A: an expandable member
strip in the selection bar; popup-menu and bottom-sheet variants were
evaluated and rejected on multi-toggle ergonomics, state-at-rest and
discoverability grounds).

## What changes

Selecting a multitrack (aggregate) gains a fifth action in the selection
bar: a "tracks" toggle that expands the pill into a second row — a
horizontally scrollable strip of one chip per member track (tint dot,
name, eye toggle). The eye hides/shows just that track; hidden members
stay in the strip, greyed, so un-hiding works from the same place. The
existing hide-all button is unchanged.

## Steps

1. `lib/ui/app_model.dart`
   - Add `List<String>? selectedMemberIds`: the selected aggregate's member
     ids captured in `selectAggregateAt`, cleared wherever the selection
     clears (miss-deselect branch, the `selectedAggregate` gone-fallback,
     `hideSelectedAggregate`, new `clearSelection()`).
   - Add `clearSelection()` (nulls `selectedAnchor` + `selectedMemberIds`,
     notifies); `map_page.dart`'s dismiss uses it instead of setting the
     field directly.
   - Add `Future<void> setSelectedMemberVisible(String trackId, bool visible)`:
     `store.setVisible`; when hiding, stop a running replay of that track
     (`player.trackRemoved`, same rule as delete); when the hidden member
     was the selection's anchor, re-anchor the selection to the aggregate
     containing the first remaining visible member and migrate the persisted
     color override (`saveAggregateColor(newAnchor, color)` then
     `saveAggregateColor(oldAnchor, '')`); finish with `_catalogDataChanged()`.
2. `lib/ui/map_actions.dart` — `SelectionBar` becomes a `StatefulWidget`:
   - Fifth action button (key `selection-tracks`, icon
     `Icons.stacked_line_chart` + member count, tooltip
     `selectionTracksTooltip`; `Icons.expand_less` while expanded) toggling
     a local `_expanded` flag, reset when `model.selectedAnchor` changes.
   - When expanded: a divider plus a horizontal `SingleChildScrollView`
     (key `selection-members`) of member chips (key `selection-member-<id>`)
     resolved from `selectedMemberIds` against `store.tracks`: tint dot via
     `model.tintKeyForTrack`, ellipsized name, and an eye `IconButton`
     (key `selection-member-toggle-<id>`, tooltip `trackHideTooltip` /
     `trackShowTooltip`) calling `setSelectedMemberVisible(id, !visible)`.
     Hidden members render greyed with `Icons.visibility_off`.
   - The actions `Row` moves into a `Column` inside the existing `Material`.
3. `lib/l10n/app_strings.dart` — new abstract getters + en + it:
   `selectionTracksTooltip` ("Tracks in this area" / "Tracce in quest'area"),
   `trackHideTooltip` ("Hide this track" / "Nascondi questa traccia"),
   `trackShowTooltip` ("Show this track" / "Mostra questa traccia").
4. `test/app_strings_test.dart` — pin the three new keys in `allStrings`.
5. Tests:
   - `test/app_model_test.dart` (aggregate group): hide a non-anchor member →
     selection survives, member hidden, aggregate re-clusters without it;
     hide the anchor with a color override set → selection re-anchors to the
     remaining aggregate and the override migrates; hide the last member →
     selection drops; un-hide restores. Plus: hiding a replaying track stops
     the replay.
   - `test/map_page_test.dart`: select an aggregate, tap `selection-tracks`,
     the strip shows one chip per member; tap `selection-member-toggle-<id>`
     → track hidden and chip greyed; tap again → shown again.
6. Verify: `flutter analyze` clean, `flutter test` passes. Commit plan +
   code + tests together.

## Notes / decisions

- Visibility plumbing (fog circles, corridors, coverage chip, drawer dots)
  already follows `StoredTrack.visible`; no changes needed there.
- Expanded state is widget-local (a view concern; the model never holds it).
- Hiding a member that splits the remaining members into several
  aggregates re-anchors to the one holding the first remaining member.
