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

1. - [ ] Per-track menu: a ⋮ button on each track tile opening a menu with
   Info, Delete and Export. Delete keeps the existing confirmation dialog;
   swipe-to-delete stays as is.
2. - [ ] Track info from the menu: a dialog with start date/time, format,
   point count, distance, duration, average speed (distance over duration).
   All strings en + it.
3. - [ ] Export from the menu: share/save the track's original stored file
   as-is (share sheet on Android, save dialog on desktop Linux) — recorded
   tracks export as the GPX they were finalized into. Widget tests for the
   menu wiring; strings en + it.

Bugs — high priority:

Recording — live trace on the map:

- [] backlog — map tilt / OsmAnd-style 3D view: excluded for now
  (owner decision 2026-11-13), revisit when flutter_map's pitch support
  releases (`MapOptions.maxPitch` — fog circles/corridors are ground
  layers and would tilt for free, so adoption stays cheap; fallbacks
  and the maplibre_gl/mapigrade comparison live in the research report),
  desktop recording (needs a Linux location source), resume of a killed
  session, auto-pause-when-stationary, interval setting,
  vector-tiles/3D-building look (needs a new map-data decision).

Recording — map controls & camera (Android first):

1. - [ ] Bottom-left action stack: move the locate button out of the top
   toolbar to the bottom-left of the map; the record button sits directly
   above it and is shown only once a position fix has been acquired; the
   top bar keeps Import / Tracks / Settings only (Fit leaves it — see the
   aggregate-track section below).
2. - [ ] Pause/resume/stop at the record slot: while recording that slot
   shows pause; pressing it turns the button into resume and a stop
   button appears before it in the same stack; stop opens a name dialog
   defaulting to the current date-time timestamp and finalizes the session
   through the unified import pipeline under that name.

Map — aggregate tracks & selection:

1. - [ ] Aggregate track model: cluster the visible stored tracks so that
   points of different tracks within ~100 m belong to the same aggregate
   track. Pure Dart behind a small interface (like the parsers), unit
   tests on synthetic fixtures: chains, singletons, threshold edge cases.
2. - [ ] Tap-to-select: tapping the map within tolerance of an aggregate's
   points selects it (visual highlight); a selection bar offers hide
   (deselect = underlying tracks visible=false), change color
   (per-aggregate override persisted in index.json) and fit screen to the
   aggregate.
3. - [ ] Remove the global Fit button from the top toolbar — fitting is per
   aggregate via selection now; the startup camera fit is unchanged.
4. - [ ] Colors: extend the tint palette beyond the current four; aggregates
   render in palette colors — the main fog aggregate keeps the fixed
   default color, distant aggregates take the next palette colors,
   overridable per selection. The Settings "track color" row now drives
   only the live recording trace color (replacing the fixed red). Strings
   en + it; widget tests for selection and highlight.

Packaging:

1. - [ ] Rename the app package com.example.unvisited →
   io.github.gianfrid.unvisited everywhere it appears: Android namespace +
   applicationId (android/app/build.gradle.kts) and MainActivity package +
   source dir, Linux APPLICATION_ID + desktop file + desktop-entry.sh,
   iOS/macOS PRODUCT_BUNDLE_IDENTIFIER. Verify with flutter analyze,
   flutter test and an Android debug build.
