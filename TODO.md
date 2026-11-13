<!-- Open work lives here; completed items are deleted, not ticked. -->

Road matching — decided architecture (research report:
docs/offline-road-matching-for-unvisited-research-report.md; owner decisions
taken 2026-11-13): osmium-filtered Geofabrik extract → offline build step →
flattened varint-polyline bucket format + JSON sidecar → pure-Dart geometric
matcher behind a byte-oriented interface → flutter_map PolylineLayer with
precomputed LOD. All `highway=*` classes; per-segment unlock at the existing
~15 m radius with ways flagged complete at ≥90% matched length; nothing
bundled in the APK (regions are user-provided files); PBF deps are
dev_dependencies of the build CLI only; unlock state persists as way ids +
matched-length ratio in `index.json`.

- [] slice 0 — record the decision: SPEC.md scope item 5 gets the chosen
  architecture (offline flattened road file, geometric matching, per-segment
  unlock, all highway classes, user-provided region files, ODbL attribution
  covered by the existing OSM notice); ARCHITECTURE.md gains a "Road
  matching" section (data flow, format, interface, persistence) replacing the
  "deferred" note; no code.
- [] slice 3 — persistence + model wiring: `index.json` gains per-track
  `unlockedWays: {wayId: matchedLength}` (survives delete-all of *other*
  tracks; deleting a track deletes its entry), computed at import time
  (or lazily on first view when a road file is present) and recomputed
  when a region file is added later. StoredTrack + TrackStore load/save
  updated; migration: old indexes load with empty maps. Tests: import
  with a road store present persists the expected way ids; re-import
  dedup keeps existing unlock state; index without the field loads.
- [] slice 4 — rendering: unlocked corridors as translucent polylines
  (same tint family as the circles) in a `PolylineLayer` above the tiles,
  merged visually with the circle overlay; culling/simplification left to
  flutter_map initially, LOD variants deferred. Widget tests: fixture
  walk renders polylines for the unlocked ways only; zoom-out band keeps
  the layer cheap.
- [] slice 5 — build CLI over real data (`tool/build_roads.dart`):
  dev_dependencies `protobuf` + `dart_osmpbf` (or hand-written reader if
  the lib proves unstable) to read an osmium-filtered `roads.osm.pbf`
  and emit the bucket format; document the osmium command in the tool's
  header + README. Manual verification per SPEC: Berlin extract →
  measure real output size, replace the report's estimates; spot-check a
  known street renders. No runtime dependency changes.
- [] slice 6 — region file UX: Settings gains "Road data" (pick a
  `.unvisited-roads` file via file_picker, store under the app root,
  swap active region; strings en+it + coverage test). Recompute unlock
  state for all tracks on region swap (progress feedback if slow).
  Tests: picker flow, region swap recomputes, missing-file fallback to
  circles-only.
- [] slice 7 — hybrid scoring (optional, only if quality demands):
  candidate preference for the previously active way to stop hopping
  between parallel roads; fixture with a service road beside a main road.
