# Plan — aggregate selection actions into the top bar (TODO.md "Recording dashboard UX (triage)", unit 5)

The aggregate selection currently renders as a large bottom-center card
(`_selectionBar` in `lib/ui/map_page.dart:655`, shown via the `Positioned`
at `map_page.dart:1257-1265`). Move its four actions — hide, color, fit,
dismiss — into the existing top `FloatingToolbar` pill, shown only while an
aggregate is selected, and delete the bottom bar.

## Steps

1. In `map_page.dart`, extract the selection actions (hide / color /
   fit / dismiss) from `_selectionBar` into a small widget (e.g.
   `_selectionActions(strings)`) returning the `Row` of action buttons,
   keeping every existing `ValueKey` (`selection-hide`, `selection-color`,
   `selection-fit`, `selection-dismiss`) and tooltips unchanged. The
   container keeps the `ValueKey('selection-bar')` so presence-based
   widget tests still work.
2. Append those actions to the `FloatingToolbar.children` list, guarded by
   `if (widget.model.selectedAnchor != null)`, after the Settings action.
   Use plain icon buttons (same icons, same callbacks) so the pill stays
   compact; the color action remains a `PopupMenuButton` with the same
   `explorationTints` items.
3. Remove the bottom `Positioned` + `SafeArea` + `_selectionBar` block and
   the now-unused `_selectionBar` method (the `Card`/padding wrapper goes
   away entirely — the pill provides the background).
4. Comment updates: the toolbar comment at ~1147 and the selection-bar
   comment at ~1251 describe the old layout; adjust to the new one.
5. Tests (`test/map_page_test.dart`): the existing selection tests tap the
   action keys and assert `selection-bar` presence — they should pass
   unchanged since keys are preserved. Add one assertion that the
   selection actions appear inside the toolbar (e.g. `find.ancestor` of
   `selection-hide` with `FloatingToolbar`) and that the bottom bar is
   gone. Run `flutter analyze` + `flutter test`.
6. Commit with this PLAN.md and remove unit 5 from TODO.md in the same
   commit.

## Notes

- While recording, the toolbar holds only Tracks/Settings; selection
  actions would join them there too if an aggregate is selected mid-session
  (selection is possible then via track-tile tap). Kept for consistency;
  revisit if it crowds.
- Bottom-left record/locate stack is untouched — this unit only moves the
  aggregate selection actions.
