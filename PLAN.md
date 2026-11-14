# Plan — shared geo math module (TODO.md, technical debt item 2)

## Problem

Haversine lives twice — `lib/models/track.dart` (`_haversine(TrackPoint,
TrackPoint)`) and `lib/recording/recording_session.dart`
(`_haversine(double, double, double, double)`) — byte-for-byte the same
formula, kept in step only by comments. `recording_session.dart` also carries
an initial-bearing `_bearing` that is the engine's course fallback and has no
other home. Any numeric tweak must be hand-mirrored or engine and catalog
distances silently disagree.

## Change

New pure-Dart module `lib/geo.dart` (no imports beyond `dart:math`,
consistent with the portability rule), exposing:

- `double haversineMeters(double lat1, double lon1, double lat2, double lon2)`
- `double initialBearingDeg(double lat1, double lon1, double lat2, double lon2)`
  (degrees clockwise from true north, as today)
- No `TrackPoint`-taking wrapper: keep the API primitive-only; `track.dart`
  calls it with `point.lat, point.lon`, one-line call sites.

Then:

1. `track.dart` — delete `_earthRadius`/`_haversine`/`_rad`, call
   `haversineMeters(...)` in `distanceMeters`; drop `dart:math` if now
   unused.
2. `recording_session.dart` — delete the local `_haversine`, `_bearing`,
   `_earthRadius`; call the shared functions at the two existing call sites;
   keep the existing doc comments on the call sites (the source of the
   agreement rationale), drop the duplicated formula comments.
3. Migrate `currentCourse`/marker behavior untouched — pure extraction, no
   logic change.

## Tests

New `test/geo_test.dart` pinning the shared module against hand-computed
values:

- haversine: zero distance for identical points; a known short leg (~1 m
  scale, 0.001° latitude ≈ 111.19 m) and a known equator longitude leg;
  antipodal sanity.
- bearing: due north, due east, due south, due west on simple legs; a
  non-trivial leg checked against a precomputed value; result wraps into
  [0, 360).
- regression: existing `recording_session_test.dart` and parser/store tests
  must pass unchanged (distance agreement between engine and catalog relies
  on them).

## Verification

`flutter analyze` clean, `flutter test` green.

## Commit

PLAN.md + the change + removal of TODO.md item 2 (technical debt list
renumbered) in one commit.
