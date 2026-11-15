# Fix faint swatches in the multitrack color selector

## Problem
The selection bar's color popup (`lib/ui/map_actions.dart` SelectionBar)
renders each swatch with the raw palette color from `explorationTints`
(`lib/ui/track_colors.dart`), whose values are translucent overlay colors
with alpha `0x33` (~20%). On the popup's solid surface this looks faint.

Every other swatch site already converts to solid:
- Settings TintSwatch: `color.withValues(alpha: 1)` (`settings_sheet.dart`)
- Track list dot: `... .withValues(alpha: 1)` (`track_list.dart`)

## Change
1. In `map_actions.dart` (SelectionBar color menu item), render the swatch
   icon with `entry.value.withValues(alpha: 1)`.

The stored tint key and the map overlay rendering are untouched; only the
popup preview becomes solid.

## Verification
- `flutter analyze` clean
- `flutter test` passes (selection/popup widget tests unaffected)

Plan confirmed by user (2025 col. conversation: "yes").
