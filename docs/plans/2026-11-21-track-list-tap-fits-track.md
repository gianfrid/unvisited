Implements: —

# Track list: tapping a track's name always jumps the camera to that track

Replaces the reverted tap-select/tap-fit scheme (f3a0cee reverts 7b9f4ed).

## Behavior

- Tapping a track's name in the drawer always fits the camera to **that
  track's own points** — every tap, no select-then-fit two-step.
- The tap also selects the containing aggregate (the pre-existing
  side effect, kept: harmless, and consistent with map-tap selection).
- The checkbox keeps controlling visibility; nothing about a tap hides
  or shows a track.

## Changes

- `lib/ui/app_model.dart` — `selectAndFitAggregate` becomes
  `selectAndFitTrack`: same selection of the containing aggregate, plus
  a per-track fit request (`fitTrackId` + `fitRequestEpoch` bump). No
  aggregate (hidden track) → no-op, as before.
- `lib/ui/map_page.dart` — the existing fit-epoch handler prefers a
  pending `fitTrackId` (fits that single track's points from
  `visibleTracks`, then clears it) and falls back to the aggregate fit.
- `lib/ui/track_list.dart` — the name tap calls `selectAndFitTrack`.

## Tests

- AppModel: tap sets `fitTrackId` and bumps the epoch; hidden track
  no-ops.
- Widget: tapping a tile zooms in from the Europe-wide fit in one tap.

## Verification

`flutter analyze` clean, `flutter test` green.
