# PLAN: Select-all delay — profile findings + loading feedback (+ cheap clustering win)

Trigger: tapping "Select all tracks" in the drawer visibly hangs the UI.

## Profile findings (throwaway benchmark, since removed)

100 synthetic tracks × 2000 points (200k points), cold caches, desktop VM:

| Step | Time |
|---|---|
| `setAllVisible` (index write + notify) | 0 ms |
| `visibleTracks` — parses all 100 track files synchronously in the build frame | 1290 ms |
| `aggregates` — `UnionFindAggregateIndex.build` over all 200k points | **5612 ms** |
| `unlockCenters` (fog circles) | 14 ms |
| Widget frame after tapping Select all | **4429 ms** |

The delay is the rebuild frame triggered by the visibility change: point
parsing + the union-find clustering run synchronously on the UI thread.
The union-find dominates — it computes a haversine for every point pair in
neighboring cells even when both tracks are already in the same cluster.

## The change

1. **Loading feedback** (`lib/ui/app_model.dart`, `lib/ui/map_page.dart`):
   `AppModel` gets its own `_busy` flag folded into the existing `busy`
   getter (`imports.busy || _busy`), which `MapPage` already renders as the
   top `LinearProgressIndicator`. `setAllVisible` becomes two-phase:
   set `_busy`, notify (spinner paints on the next frame), yield one frame
   (`Future.delayed(Duration.zero)`), then apply the visibility change and
   notify (the heavy rebuild frame), and clear `_busy` in a post-frame
   callback so the spinner stays up through the rebuild. Same treatment is
   *not* needed for `toggleVisible` (one track — sub-frame).
2. **Cheap clustering win** (`lib/aggregate/aggregate_tracks.dart`): in
   `UnionFindAggregateIndex.build`, skip the haversine when
   `find(t) == find(other)` — the union would be a no-op anyway, so this
   is semantics-preserving and cuts most of the 5.6 s on chained catalogs.
3. **Tests**: `test/app_model_test.dart` — `busy` is true during
   `setAllVisible` and false after the post-frame clear. `test/aggregate_tracks_test.dart`
   — clustering results unchanged with the early exit (existing tests cover
   this; add one chained-catalog case asserting identical grouping).
   `test/map_page_test.dart` — widget test: tapping "Select all tracks"
   shows the progress indicator while busy and clears it after.

## Verification

- Re-run the same synthetic benchmark (as a scratch test, not committed)
  to confirm the frame time drops and the spinner appears.
- `flutter analyze` clean, `flutter test` passes.
- Commit with PLAN.md; then `tool/build_release_apk.sh` detached.

## Out of scope

- Async/chunked point parsing (would remove the 1.3 s parse too, but is a
  bigger change than the reported ask); revisit if feedback alone isn't
  enough on real catalogs.
