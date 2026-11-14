<!-- Open work lives here; completed items are deleted, not ticked. -->

Road matching — decided architecture (research report:
docs/offline-road-matching-for-unvisited-research-report.md; owner decisions
taken 2026-11-13): osmium-filtered Geofabrik extract → offline build step →
flattened varint-polyline bucket format + JSON sidecar → pure-Dart geometric
matcher behind a byte-oriented interface → flutter_map PolylineLayer with
precomputed LOD. All `highway=*` classes; per-segment unlock at the existing
~15 m radius with ways flagged complete at ≥90% matched length; nothing
bundled in the APK (regions are user-provided files); the build CLI's PBF
reader is dev-tool-only (hand-written in `tool/`, no package dependency);
unlock state persists as way ids + matched-length ratio in `index.json`.

Recording + ride/walk dashboard — decided architecture (research report:
docs/active-recording-for-unvisited-research-report.md; owner direction
2026-11-13: recording is in scope, Android first, the app stops being
specified as view-only; the tilted/3D map view is excluded for now and
parks in the backlog): geolocator's Android foreground service (no new
packages) → pure-Dart RecordingSession behind a PositionSource interface →
1 s best-accuracy intake with filters (>50 m accuracy dropped, stale via
maxUpdateAge, pause/fix-loss = new trkseg) → staging GPX under
`recording/` with short flush cadence → stop finalizes through the existing
unified import pipeline (dedup, fog, road corridors all unchanged) →
dashboard HUD (speed, distance, duration/moving time, follow-camera,
course-up marker). Background location is deliberately never requested
(sessions start only from the Record button); process death salvages the
staged file as a partial track on next start. Desktop recording is backlog
(no Linux location plugin).

Track list — catalog UX:

Settings about text — accuracy fix:

- [] slice 9 — drop the local-only claim from the Settings About card:
  `aboutDescription` says "Local-only track recording and exploration on
  OpenStreetMap" (en) / "…solo in locale" (it), but map tiles are fetched
  from the OSM tile service, so the app is not local-only. Reword both
  languages (keep what stays true — imports, index and recordings are
  stored on-device; only the tile fetch goes to the network); update the
  strings/language tests that assert the text.

- [] backlog — map tilt / OsmAnd-style 3D view: excluded for now
  (owner decision 2026-11-13), revisit when flutter_map's pitch support
  releases (`MapOptions.maxPitch` — fog circles/corridors are ground
  layers and would tilt for free, so adoption stays cheap; fallbacks
  and the maplibre_gl/mapigrade comparison live in the research report),
  desktop recording (needs a Linux location source), resume of a killed
  session, auto-pause-when-stationary, interval setting,
  vector-tiles/3D-building look (needs a new map-data decision).
- [] open decisions (report §Open questions): confirmed defaults — 1 s
  interval, soft battery advisory, mute-FGS when notifications denied,
  manual pause only, salvage-as-import.
