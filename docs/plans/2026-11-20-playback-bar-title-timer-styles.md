Implements: —

# Playback bar: differentiate the track title from the timer

## Goal

In the playback bar's row, the track name and the `elapsed / total`
readout currently render at the same visual weight (plain default and
`bodyMedium`), so the title doesn't read as the title. Give them
distinct roles following the app's existing conventions.

## Design decisions

- **Track name → primary:** `bodyMedium` + `fontWeight: FontWeight.w600`
  (the same emphasis `track_list.dart`'s stat labels and `map_actions.dart`
  use), keeping `maxLines: 1` + ellipsis.
- **Timer → secondary metadata:** `bodySmall` in
  `Theme.of(context).colorScheme.onSurfaceVariant` (muted), plus
  `FontFeature.tabularFigures()` so the ticking digits don't jitter the
  row width every second.
- No layout change: same row, same order, same keys — the existing
  widget tests (`playback_widget_test.dart`) keep passing unmodified
  except where they assert on style (they assert on text, so none
  change).

## Steps

1. Restyle the two `Text`s in `lib/ui/playback_dashboard.dart`'s `_bar`.
2. `flutter analyze` clean, `flutter test` pass (widget tests assert the
   timer text, e.g. `00:15 / 00:30` — unchanged content, only style).
3. Commit the dashboard, this plan, message "Playback bar: title/timer
   visual hierarchy".

## Non-goals

- No new strings, no layout restructuring, no changes to the slider or
  the buttons.
