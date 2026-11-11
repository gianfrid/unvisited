# Unvisited

Android app (Flutter) that imports GPS tracks from multiple sources and plots all of them together on one OpenStreetMap-based map. Companion to recording apps (OpenTracks, Garmin devices, Strava exports) — this app does not record activities.

## Scope (MVP)

1. Import tracks from local files via Storage Access Framework (SAF) folder access and share intents. No per-service integrations, no cloud, no backend, no accounts.
2. Format priority, in order: GPX first (universal), then FIT, then KMZ, then TCX. All sources flow through one unified import pipeline.
3. Persist imported tracks locally as files (local-only storage).
4. Show every imported track together on a single map using OpenStreetMap tiles.
5. No in-app recording. No explored/unexplored road coloring, no OSM road matching, no route planning yet — those come after this prototype works.

## Import sources and constraints

- OpenTracks: first-class source. Its data lives in an app-private directory; exports arrive as KMZ/KML/GPX written to a user-chosen directory or via the share sheet. Import via SAF folder access or share intent only.
- Garmin (Instinct gen 1 and Instinct 3 test devices): FIT files in `GARMIN/Activity/` (older firmware: `GARMIN/ACTIVITY/` — treat folder names case-insensitively). On Android, USB-OTG + SAF DocumentsProvider can browse the watch storage directly.
- Strava: GPX exports or the bulk archive (original FIT files).
- FIT parsing rules:
  - Key off the FIT File Id message: type 4 = activity, type 32 = monitoring. Do not branch on filename or folder path.
  - Skip `monitoring` FIT files (`GARMIN/Monitor/`, all-day health metrics). Naive "import every .fit" is wrong.
  - Tolerate truncated FIT files (missing summary/session block, e.g. battery death mid-ride) and Smart Recording's variable intervals plus pause events.

## Architecture decisions

- Flutter frontend. Parsing and future OSM matching should stay portable; a Rust core behind Dart FFI (flutter_rust_bridge) is the preferred path for FIT parsing. Pure-Dart GPX/KMZ parsing is fine.
- Data is local only. No cloud sync, no server component, no analytics.
- Track deduplication matters: multiple sources may export the same activity.

## Working agreements

- Implement in small vertical slices; each slice ends with unit tests against fixture files in `test/fixtures/`.
- Never add network calls beyond fetching OSM map tiles.
- Keep import parsing logic decoupled from UI widgets so it is unit-testable.
- Ask before adding packages beyond the established set (flutter_map, file_picker or SAF equivalents, a database such as drift if persistence needs it).