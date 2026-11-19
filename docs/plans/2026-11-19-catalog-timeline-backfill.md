# Catalog timeline self-heal on track open

Implements: —

Bug (found reviewing playback on a real catalog): tracks imported before
the index carried `durationSeconds` keep `null` in the catalog — the
playback menu gate (and the Info dialog's Duration/Avg speed rows) read
that metadata and refuse, although the stored files themselves are fully
timestamped. Deliberate re-import cannot fix it: content-hash dedup skips
the update.

The decided fix is the user's: **heal on every track open** — when a track is opened (`TrackStore.loadPoints`, where the file is parsed anyway), any missing `durationSeconds` / `startTimeUtc` is filled from the parsed timeline and persisted. No startup sweep: hidden, never-opened tracks keep their stale metadata (and their greyed playback entry) until first open — visible tracks are opened by the map overlay at startup, so they heal on the first launch. This matches the app's self-healing philosophy (the road-file restore) and heals hand-edited or future-stale indexes for free, at zero extra parse cost.

## Steps (one slice)

1. `StoredTrack.durationSeconds` / `startTimeUtc` become mutable (the
   class already has mutable presentation state — `visible`).
2. `TrackStore.loadPoints`: after a successful parse, if either field is
   null, fill it from the parsed `TrackData` (`startTime?.toUtc()`,
   `durationSeconds` when the data has one) and persist via the existing
   index write — only when something actually changed. A parse that
   yields no timeline leaves the fields null (never fabricated); an
   unreadable file was already a null return.
3. Tests (`track_store_test.dart`): a legacy entry (null fields, timed
   file) is healed by one `loadPoints` and the healed values persist
   across a store reopen; an untimed file stays null; an already-set
   field is never overwritten; the import path is unchanged.
4. Commit with the plan; the playback gate stays metadata-based (now
   reliable for every opened track).
