# Plan — aggregate tracks & selection (TODO.md "Map" section, 4 items)

Implemented as four vertical slices, each ending with tests and a commit.

## Slice 1 — aggregate track model (pure Dart)

New `lib/aggregate/aggregate_tracks.dart` behind a small interface (like the
parsers):

```dart
abstract class AggregateIndex {
  /// Clusters the given tracks' points into aggregates; points of different
  /// tracks within [thresholdMeters] belong to the same aggregate.
  List<AggregateTrack> build(Iterable<MapTrackLike> tracks, {double thresholdMeters});
}

class AggregateTrack {
  final List<String> trackIds;       // member catalog tracks
  final List<LatLng> points;         // all member points
  String get anchorId;               // earliest-starting member; the
                                     // stable key for persisted overrides
}
```

- Clustering: union-find over tracks, joined when any point pair is within
  ~100 m (spatial hash at cell = threshold, 3×3 neighborhood query, same
  trick as the road matcher's segment index — O(n) per area, not O(n²)).
- Pure Dart, no Flutter imports; `MapTrackLike` = id + points + start time
  so the model's `MapTrack` slots in unchanged and the anchor is computable.
- Unit tests on synthetic fixtures in `test/aggregate_tracks_test.dart`:
  chains (A–B–C via B), singletons, threshold edge cases (99 m joins,
  101 m doesn't), empty input.

## Slice 2 — tap-to-select + selection bar

- `AppModel` gains selection state: `AggregateTrack? selected`, computed
  lazily from `visibleTracks` (cache keyed by visible-track id set).
- Map tap handler: within tolerance (~screen-pixel equivalent at zoom, same
  math family as the fog radius) of any aggregate point → select it; else
  deselect.
- Selection bar (bottom sheet / top bar while a selection is active):
  Hide (sets each member track `visible=false` via the store, then
  deselects), Change color, Fit. Visual highlight: the aggregate's circles
  drawn in a brighter/opaque tint on top.
- Per-aggregate color override persisted in `index.json`
  (`aggregateColors: {anchorTrackId: tintKey}`). The key is the *anchor* —
  the member track with the earliest start time — not a hash of the whole
  member set: adding or removing other tracks leaves the anchor (and so
  the persisted color) untouched. Only deleting the anchor re-keys the
  aggregate (the next-oldest member becomes the anchor).
- Widget tests in `test/map_page_test.dart`: tap selects, bar actions work,
  deselect restores visibility.

## Slice 3 — remove the global Fit button

- `map_actions.dart`/toolbar: drop the Fit action; startup camera fit
  unchanged. Selection bar's Fit covers per-aggregate fitting.

## Slice 4 — palette & colors

- `track_colors.dart`: extend `explorationTints` beyond the four (add ~4
  more), keep `defaultTintKey` for the main fog aggregate.
- Aggregates render in palette colors by rank (main = default tint; others
  next palette colors), overridable per selection (from slice 2).
- Settings "track color" row now drives only the live recording trace color
  (replacing the fixed `Colors.redAccent` in map_page) — a new
  `settings.recordingTint`, persisted like the others, default red.
- Strings en + it for the new selection bar labels; widget tests for
  highlight/selection colors.

## Verification per slice

`flutter analyze` clean, `flutter test` green (all existing suites plus the
new ones). TODO.md entries removed in the same commit as their slice.
