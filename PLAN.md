# Slice 12 — drop the date column from the track tile

## Context

`_TrackTile`'s trailing `secondary` row is a date label plus the delete
`IconButton`. The date takes horizontal space the (ellipsized) track
name needs, and filenames usually already carry a date. The subtitle
(format · points · distance · duration, slice 7) is the tile's metadata;
the date goes away entirely. The delete button stays (mouse users have
no swipe equivalent).

## Steps

1. `lib/ui/map_page.dart` — `_TrackTile`:
   - delete the `date` local and the `Flexible(Text(date…))`;
   - the `secondary` row collapses to the delete `IconButton` alone —
     drop the now-pointless `Row` wrapper and pass the button directly.
2. Widget test (`test/map_page_test.dart`):
   - import `morning_walk.gpx`, open the drawer, assert the tile shows
     the subtitle (format · 5 points · distance · 04:00) and *no*
     date text (`2024-05-01` absent), and the delete button remains.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 12 TODO entry; PLAN.md
  carries over to the next task unmodified.
