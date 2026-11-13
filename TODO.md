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

- [] profiling follow-ups (the Berlin numbers are desktop; they leave the
  open questions on Android): the JSON
  bucket payloads dominate open/parse cost at region scale; if a real
  Germany-sized file proves too slow on mid-range Android, switch the bucket
  payload to a binary layout (varint lengths instead of JSON) — the directory
  and lazy-loading design stays. Also re-run `tool/bench_roads.dart` on a
  device profile build before deciding on the Rust core (hybrid scoring).
- [] slice 7 — hybrid scoring (optional, only if quality demands):
  candidate preference for the previously active way to stop hopping
  between parallel roads; fixture with a service road beside a main road.
