# Adaptive lane offsets: no offset where a track is alone

Implements: —

Bug report (user): in member-picking mode some tracks render offset even
where only one track uses that road, and it is more visible when zoomed
out. Cause: `_memberLanes` applies a constant global lane offset per
member (`(lane - (n-1)/2) * laneMeters`), so in an N-member selection
every member but the center lane is shifted sideways along its whole
length — including stretches where it is the only track there. At low
zoom the decimated segments are long, so the shift reads against the fog
corridor.

## Change

- `lib/ui/lane_offset.dart` — replace the constant-offset application
  with per-vertex adaptive offsets, pure Dart + unit tests:
  - `List<double> laneOffsetsPerVertex(List<LatLng> points, {required int
    selfIndex, required List<List<LatLng>> membersPoints, required double
    laneMeters, required double overlapMeters})`: buckets all members'
    points into a grid (cell edge = overlapMeters, cos-lat scaled, like
    the aggregate scan), and for each vertex collects the members with a
    point within `overlapMeters`, sorted by member index; the vertex's
    offset is `(rank - (count-1)/2) * laneMeters`. A track alone at a
    vertex (count = 1) gets offset 0 — it sits on its true geometry, on
    top of its fog corridor. Where k members overlap they split
    symmetrically: ±0.5, ±1.5, … laneMeters.
  - `offsetLanePoints` gains a per-vertex mode: shift each vertex along
    its averaged segment perpendicular (existing math) by
    `offsets[i]` instead of a constant. Constant behavior stays
    available via a uniform list (keeps old tests meaningful).
- `lib/ui/map_page.dart` `_memberLanes()` — decimate each member first,
  compute all members' decimated point lists, then per member compute
  `laneOffsetsPerVertex` with `overlapMeters = 2.5 * laneMeters` (≈7.5
  screen px — tracks that close share screen space) and apply per-vertex
  offsets. Single-member selections now render exactly on the geometry
  at every zoom. Lane cache key unchanged (still per zoom half-step +
  member list + visibility).
- Hit-testing (`_laneCandidatesAt`) uses the same per-vertex offset
  polylines, so aim = hit stays true.

## Tests

- `test/lane_offset_test.dart`: alone track → all-zero offsets; two
  overlapping tracks → symmetric ±0.5 lane at shared vertices, 0 where
  apart; three-way overlap → -1, 0, +1 lane; degenerate inputs.
- Existing widget tests keep passing (bubble flow, tie cycling —
  coincident tracks still get adjacent offsets at shared vertices).

## Verify

`flutter analyze` clean, `flutter test` passes. Commit plan + change.
