# Slice 7 — duration in the track list

## Context

`TrackData` already computes `startTime` (first point with a timestamp)
and `distanceMeters`; `StoredTrack` persists `startTimeUtc` in
`index.json`; the track tile subtitle shows `format · points · distance`
with the date in the trailing slot. Recorded GPX carries point times, so
a recorded ride gets duration for free once the pipeline carries it.

## Steps

1. `lib/models/track.dart` — `TrackData` gains `endTime` (last point
   carrying a timestamp) and `durationSeconds` (end − start in seconds,
   null when either end is missing; negative span clamped to null).
2. `lib/storage/track_store.dart` — `StoredTrack` gains
   `double? durationSeconds`, persisted as `durationSeconds` in
   `index.json` next to `distanceMeters`; `fromMap` treats it as optional
   so old indexes keep loading; the import path sets it from
   `data.durationSeconds`.
3. `lib/ui/map_page.dart` — `_TrackTile` subtitle becomes
   `format · points · distance · duration` using the existing
   `_formatDuration` helper, with a dash (not a stray value) when the
   track has no timestamps. The date stays in the trailing slot — only
   duration moves into the subtitle.
4. Tests:
   - model/store round-trip: import a GPX fixture with timestamps via
     `TrackStore.importBytes`, assert `durationSeconds` on the stored
     track, reload the store from disk, assert it round-trips; an old
     index without the field loads as null;
   - widget test: a track tile shows the formatted duration between
     distance and date;
   - recorded-track coverage comes via the staging GPX path (the stage
     writer already emits `<time>`), asserted at the model level by
     importing the staged bytes.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 7 TODO entry; PLAN.md
  carries over to the next task unmodified.
