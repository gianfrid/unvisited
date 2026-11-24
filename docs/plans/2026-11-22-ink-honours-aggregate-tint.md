# Ink trace style honours the aggregate's tint (multitrack color edit)

Implements: — (bug report: "the ink track color is not modifiable from
multitrack edit")

## Problem

The selection bar's palette (`selection-color` → `model.setAggregateColor`)
saves a tint key per aggregate anchor, and the map reads it through
`aggregateTintKeys`. The circles and pencil styles honour it; the ink style
does not — `_buildFogLines` (and the ink selection highlight) draw every
stroke in the constant `inkHue`, so picking a colour for a selected
multitrack changes nothing on screen while ink is active.

## Design

Keep ink reading as ink, but derive its colour from the aggregate's tint:
`inkColorFor(tintKey)` in `track_colors.dart` takes the tint at full
opacity and blends it ~55% toward the deep ink base (`inkHue`), so the
stroke keeps its hue identity while staying dark enough to read as pen ink
over the tiles. Distinct tints stay distinguishable; `inkHue` remains the
neutral base (used by the blend, not directly by the renderer).

- `lib/ui/track_colors.dart` — `Color inkColorFor(String tintKey)`, plus a
  doc note that ink is tint-derived, not a fixed hue.
- `lib/ui/map_page.dart` — `_buildFogLines` and the ink branch of
  `_selectionHighlightLayers` use `inkColorFor(tintKey)` instead of
  `inkHue`; per-pass alphas unchanged, selection still full opacity.
- Tests:
  - `test/track_colors_test.dart` (new, or the existing colour test file)
    — every tint maps to a distinct, opaque ink colour; different tints
    never collide; the result is darker than its source tint.
  - `test/map_page_test.dart` — with ink active, `setAggregateColor`
    changes the rendered stroke colours (and an unset aggregate keeps
    the default-derived ink colour).
- Docs — ARCHITECTURE rendering paragraph: ink colour derives from the
  aggregate tint (multitrack colour edit applies to every trace style).
- Verify: `flutter analyze` clean, `flutter test` passes; commit plan +
  change in one commit.
