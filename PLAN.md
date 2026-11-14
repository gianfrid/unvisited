# Plan — selection actions as a second compact pill below the toolbar (follow-up to unit 5)

The one-pill layout crowds at narrow widths (Settings + 4 selection actions
in the top pill). Split it:

1. `lib/ui/map_page.dart`: stop appending `_selectionActions` to the top
   `FloatingToolbar.children`. Instead, overlay a second compact pill
   directly below the toolbar when `widget.model.selectedAnchor != null`:
   a `Column` at `Alignment.topCenter` holding the toolbar and, beneath it,
   an icon-only pill. Largest toolbar so far is 3 actions; adding the pill
   below never widens it.
2. Reuse the current `_selectionActions` Row as the pill's content —
   keep all `ValueKey`s (`selection-bar`, `-hide`, `-color`, `-fit`,
   `-dismiss`) and tooltips; give it the same `Material` + rounded pill
   styling (elevated surface, radius 24, horizontal padding) that
   `FloatingToolbar` uses, so it visualizes as "attached" to the toolbar.
3. Update the assertion added in the previous commit: `selection-hide`'s
   ancestor is no longer `FloatingToolbar` — assert it sits in a sibling
   pill below the toolbar instead (e.g. two `Material` pills, selection
   actions' offset below the toolbar's). Adjust other selection tests as
   needed (they tap keys, so mostly unaffected).
4. `flutter analyze` + `flutter test`, then a visual check via
   `flutter run -d linux` if desired.
5. Commit (PLAN.md included in the same commit; TODO.md already has no
   unit for this — it refines unit 5, already removed).
