# Unvisited — Backlog

Parked decisions: considered, deliberately not being worked on. Nothing here
is a commitment; each entry records why it was parked and what would reopen
it. Decided architecture lives in [ARCHITECTURE.md](ARCHITECTURE.md) and the
rules in [SPEC.md](SPEC.md); open work in [TODO.md](TODO.md).

## Recording

- **Desktop recording** — geolocator ships no Linux implementation, so there
  is no location source to plug behind the `PositionSource` interface;
  the Record action is hidden where location support is absent. Revisit if a
  usable Linux position source appears.
- **Resume of a killed session** — startup salvage imports the staged file as
  a partial track instead; resuming the live session state is heavier than
  v1 needs.
- **Auto-pause when stationary** — parked; the pause/resume state machine and
  the fix-loss trkseg break would be the natural seams for it.
- **Recording interval setting** — parked; the 1 s best-accuracy intake is
  fixed for now, the setting would be a preference behind the same intake.

## Map

- **Map tilt / OsmAnd-style 3D view** — excluded for now (owner decision
  2026-11-13). Revisit when flutter_map's pitch support releases
  (`MapOptions.maxPitch`; fog circles/corridors are ground layers and would
  tilt for free, so adoption stays cheap). Fallbacks and the
  `maplibre_gl`/`mapigrade` comparison live in
  `docs/active-recording-for-unvisited-research-report.md`.
- **Vector tiles / 3D buildings** — would be a new map-data decision
  (raster OSM tiles are the only source under any future tilt work); out of
  scope pending an explicit owner decision.
