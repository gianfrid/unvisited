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

Technical debt — high priority (owner-approved 2026-11-14; findings above
the rest of the backlog by intent):

1. - [ ] Fix the startup-salvage UTF-8 corruption: `_salvageRecordings`
   re-encodes the read GPX with `gpx.codeUnits` (lib/ui/app_model.dart:666)
   — UTF-16, not UTF-8 — so any non-ASCII character in a staged track name
   (an accented name from the stop dialog) lands corrupt. Use
   `utf8.encode`; add a unit test with a non-ASCII name; fix the same
   pattern in test/app_model_test.dart:837 while there.
2. - [ ] Split lib/ui/map_page.dart (2K lines, 14 classes) into `ui/`
   modules: `_SettingsSheet`, `_StatsPanel`, the zoom slider, the drawer
   (make `TrackDrawer` private) + `_TrackTile`, the bottom-left action
   stack and toolbar widgets. No behavior change; widget tests assert by
   text/tooltip and must keep passing untouched.
3. - [ ] Test harness extraction: `mockGeolocator` and the repeated
   `createRoot` + temp-dir + `MaterialApp`/`MapPage` setup (43 copies in
   test/map_page_test.dart) become shared helpers in test/helpers.dart or
   a pump harness; shrinks the 2.4K-line test file materially.
4. - [ ] Split lib/ui/app_model.dart (868 lines, 6 concerns): a recording
   controller (start/stop-with-name/pause/salvage staging) and an import
   coordinator (the three near-parallel import paths collapsed onto one
   helper for the store+roads+cache+summary choreography), keeping
   settings/locate on the model.
5. - [ ] Extract the duplicated haversine/bearing formulas (identical
   twins in lib/models/track.dart and lib/recording/recording_session.dart
   kept in step by comments only) into one shared pure-Dart geo module.
6. - [ ] Per-fix repaint granularity: `notifyRecordingFix` notifies the
   whole tree at 1 Hz and `liveSegments` deep-copies every segment per
   rebuild — a scaling wall for long sessions. Give the recording live
   state its own Listenable (stats/trace/marker) so the fog overlay and
   toolbar rebuild channels stay untouched.
7. - [ ] pubspec cleanup: drop the Flutter template comment block; remove
   the unused `cupertino_icons` dependency (zero CupertinoIcons usage —
   the cupertino.dart import in main.dart is the locale delegate and
   stays). Package removal per SPEC: confirm with owner in the plan step.

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

1. - [ ] Test the engine's `currentHeading`/`currentCourse` split (the
   state itself landed in b6fdfe8 with getter docs claiming "unit tests
   both ways" — its diff touched no test file; the message overclaimed).
   Unit tests for the two behaviors: a fix that carries a heading sets
   both getters to it; a heading-less fix leaves `currentHeading` null
   while `currentCourse` keeps bridging the bearing between fixes.
2. - [ ] Gate the course-up camera rotation on the device-reported
   heading — the magnetometer-backed signal — so a sensor-less or
   bearing-only stream keeps the camera north-up with the marker still
   rotating; and smooth what remains (the course-delta hysteresis below
   the threshold landed in b6fdfe8, but the rotation still rides
   `currentCourse` — map_page.dart has no `currentHeading` gate, so a
   bridged-bearing stream still spins the camera). No new packages: a
   dedicated magnetometer plugin would be a package decision beyond the
   established set — the gate rides the heading the position fixes
   already report.

Recording — live trace on the map:

- Backlog (not completable work, parked decisions): map tilt /
  OsmAnd-style 3D view: excluded for now
  (owner decision 2026-11-13), revisit when flutter_map's pitch support
  releases (`MapOptions.maxPitch` — fog circles/corridors are ground
  layers and would tilt for free, so adoption stays cheap; fallbacks
  and the maplibre_gl/mapigrade comparison live in the research report),
  desktop recording (needs a Linux location source), resume of a killed
  session, auto-pause-when-stationary, interval setting,
  vector-tiles/3D-building look (needs a new map-data decision).

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
