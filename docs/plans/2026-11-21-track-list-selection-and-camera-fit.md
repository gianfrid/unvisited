Implements: TODO.md — Track list: separate camera fit from selection

# Track list: tap selects; a second tap fits the camera to the single track

## Behavior

Tapping a track's name in the drawer:
- **Not yet selected** → select the track's aggregate (`selectedAnchor`), no camera move. The drawer stays open.
- **Already selected** → fit the camera to **that track's own points** (not the whole aggregate's), keeping the drawer open.

The checkbox keeps its current role (visibility). Nothing else changes: map-tap selection, the selection bar, playback, and the fit-on-import/watch epoch paths are untouched.

## Changes

### `lib/ui/track_list.dart`

`_TrackTile`'s name `onTap`: `model.selectAndFitAggregate(track)` → `model.tapTrack(track)`.

### `lib/ui/app_model.dart`

- `bool isTrackSelected(StoredTrack t)` — true when the selected aggregate contains `t.id` (false for hidden tracks; they have no aggregate).
- `void tapTrack(StoredTrack t)` — the tile's whole tap policy:
  - unselected (and visible) → select the containing aggregate, no epoch bump;
  - already selected → set `fitTrackId = t.id`, bump `fitRequestEpoch`, notify.
- `String? fitTrackId` — the pending per-track fit request; MapPage consumes and clears it.
- `selectAndFitAggregate` stays as-is if anything else still calls it, otherwise it goes.

### `lib/ui/map_page.dart`

In the existing `fitRequestEpoch` change handler: when `model.fitTrackId` is set, fit to that track's points (`visibleTracks` already carries them as `MapTrack`s) and clear the request; otherwise fall back to `selectedAggregate.points` (the current behavior).

## Tests

- AppModel unit test: `tapTrack` selects on first tap (no epoch bump), bumps the epoch with `fitTrackId` on the second, no-ops on invisible tracks.
- Widget test (MapPage, narrow surface): drawer open → tap name → selection bar appears, camera unmoved; tap again → camera fits to the track's own points; drawer still open.

## Verification

- `flutter analyze` clean, `flutter test` green.
