# Slice 8 — track list ordered most-recent-first

## Context

The tracks drawer builds its `ListView` straight off `model.tracks`, i.e.
import order. It should read most-recent-first: `startTimeUtc` descending,
timestamp-less tracks last, stable (original catalog order) within each
group. Dart's `List.sort` is not guaranteed stable, so the comparator must
tiebreak on the original position.

## Steps

1. `lib/ui/map_page.dart` — in the tracks drawer, display order only:
   build the list for the `ListView.builder` by pairing each track with
   its position in `model.tracks` and sorting by `startTimeUtc`
   descending, nulls last, original position as the tiebreak. The
   catalog itself (`model.tracks`), the index file and the map overlays
   are untouched — this is presentation order.
2. Widget test (`test/map_page_test.dart`): imports in mixed order —
   `recorded_ride.gpx` (2024-05-01 18:00), `morning_walk.gpx` (07:05),
   `activity_ride.gpx` (08:00), plus an inline timestamp-less GPX — open
   the drawer, then read the displayed order from the tiles'
   `ValueKey('track-<id>')` (on the `Dismissible`s) and assert
   recorded → ride → walk → timeless.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 8 TODO entry; PLAN.md
  carries over to the next task unmodified.
