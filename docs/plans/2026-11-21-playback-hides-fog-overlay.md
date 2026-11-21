# Playback hides the fog-of-war overlay

Implements: —
(direct user request: "remove the track fog of war points when using the
playback function", clarified — hide the **entire** fog circle overlay while
a replay runs; road corridors stay)

## What it does

While a track replay runs, the fog-of-war **circle overlay** is hidden: the
map shows tiles (and road corridors, untouched) with the replay's trace and
marker riding over them. On close, the circles return. The whole-overlay
read is the user's choice: circles clutter the replay, and per-track removal
(distinct from the other members' circles inside a shared aggregate) is
not what they asked for.

Road **corridors** — the companion polyline overlay of unlocked OSM ways —
stay visible in every case (explicitly confirmed). So does the selection
highlight, which is a selection affordance, not the fog itself.

## Design

- Presentation-only, no persistence, no new state: the fog layer is a
  direct child of the map's `children`, and a running replay is already a
  model-wide rebuild trigger (`PlaybackController.start`/`stop` fire
  `onChanged`, mounting/unmounting map layers). Making the layer
  conditional on `widget.model.playback == null` means:
  - start → page rebuild → no `CircleLayer`;
  - stop → page rebuild → `_buildFogCircles` runs again (the
    `_fogCentersByAnchor` cache still holds its centers, so the return is
    cheap).
- Per-tick repaints already never touch the fog (they fire only
  `playbackLive`), so the gate costs nothing during playback.
- No changes to `fog_of_war.dart`, `app_model.dart`, or the playback
  modules.

## Steps

1. `lib/ui/map_page.dart` — replace the unconditional
   `CircleLayer(circles: _buildFogCircles(mapTracks))` with
   `if (widget.model.playback == null) CircleLayer(...)` and update the
   neighboring comments that say the replay "reads on top of the fog" /
   "rides it": during a replay there is no fog to ride — the trace and
   marker ride the bare map plus corridors.
2. Docs — one-sentence updates where the layers are described:
   - `ARCHITECTURE.md` (map/layers section: a running replay hides the
     circle layer; corridors are unaffected),
   - `SPEC.md` item 7 (track playback): a replay hides the fog-of-war
     circle overlay while it runs; corridors stay.

## Tests

`test/playback_widget_test.dart` — one new widget test beside the
start/stop tests ("the replay hides the fog-of-war overlay"):
- import a timed track (the existing `eastwardGpx` helper) and pump the
  map page: the fog `CircleLayer` is mounted with a non-empty `circles`
  (one visible track unlocks cells);
- start the replay through the ⋮ menu (the existing `openTrackMenu`
  helper): no `CircleLayer` remains (there is no selection highlight in
  this setup, so the count goes to zero) and the replay marker is
  present — the layers the replay may keep are its own;
- close the replay (`playback-close`): the `CircleLayer` is back with
  the same non-empty circles.

## Verification

- `flutter analyze` clean, `flutter test` green.
- Manual (desktop, optional): import a track, start playback — circles
  vanish, corridors (with a region file) stay — close — circles return.

## Commit

One slice: the layer gate, the comment updates, the doc sentences, the
widget test, and this plan file, in a single commit
("Playback: hide the fog-of-war overlay while a replay runs").
