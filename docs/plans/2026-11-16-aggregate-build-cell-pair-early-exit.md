# Optimize aggregate clustering: cell-pair early exit + cheap pre-filter (no schema change)

Implements: —

## Problem

"Select all tracks" with ~25 tracks takes seconds. `AppModel.aggregates`
rebuilds via `UnionFindAggregateIndex.build` whenever the visible set changes.
The current build already buckets points into a threshold-sized lat/lon grid
and scans the 3x3 neighborhood per point, skipping the haversine when the two
tracks are already united — but it still *iterates* every cross-track point
pair in neighboring cells, and calls haversine for every not-yet-united pair.

Measured on a synthetic 25-track / 100k-point catalog (10 dense tracks that
all unite + 10 parallel near-miss tracks 150 m apart + 5 singletons), current
implementation: ~2.9 s and 3.18 M haversine calls.

## Semantics (unchanged)

Two tracks join iff at least one point pair is within the threshold
(transitively). The optimization is purely computational; the partition
produced is identical.

## Plan

1. `lib/aggregate/aggregate_tracks.dart` — restructure the neighbor scan from
   per-point to per-cell-pair:
   - Track, per grid cell, the set of track indices present in it.
   - Visit each unordered pair of neighboring cells once (not per point).
   - Before scanning a cell pair's points, check whether every track in one
     cell is already united with every track in the other (union-find `find`
     equality). If so, skip the pair entirely — the "stop after the first
     near point" effect at cell granularity; this is what removes the cost
     on dense/chained catalogs once tracks unite.
   - Within a scanned pair, keep the cheap `find` skip per point pair and add
     a degree-space reject (`|dLat| <= threshold/111320`,
     `|dLon| <= threshold/(111320*cosLat)`) before the haversine, so
     near-miss parallel tracks cost a comparison, not trig.
   - Same union condition (haversine <= threshold), same transitive
     clustering, same output shape.
2. Measured prototype (scratchpad, self-contained copy): ~2.9 s -> ~0.14 s
   warm on the same catalog, haversine calls 3.18 M -> 3.6 k, identical
   partition.
3. Tests (`test/aggregate_tracks_test.dart`): the 8 existing tests must pass
   unchanged (semantics preserved). Add a deterministic property test: a
   brute-force O(n^2) reference partition vs `build` on a seeded random
   synthetic catalog (mixed clusters, chains, near-misses) must agree.
   No timing-based test (flaky).
4. On the no-DB suggestion: not needed, and not relaxed. SPEC's rule is
   "JSON index by design, never a database package" — precomputing
   pairwise relations at import would mean persisting derived union state in
   `index.json` and incrementally maintaining it across import/dedup/delete.
   With the in-memory build at ~0.1 s for 25 tracks there is no payoff for
   that complexity; the index schema stays untouched.
5. Verify: `flutter analyze` clean, `flutter test` passes; commit plan +
   change together.
