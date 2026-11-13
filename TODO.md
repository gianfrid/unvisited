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

Recording + ride/walk dashboard — decided architecture (research report:
docs/active-recording-for-unvisited-research-report.md; owner direction
2026-11-13: recording is in scope, Android first, the app stops being
specified as view-only): geolocator's Android foreground service (no new
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

- [] slice 1 — recording engine, pure Dart: `RecordingSession` + filters +
  stats (distance/duration/moving speed) + incremental GPX 1.1 writer
  (trkseg discipline, flush cadence) behind a `PositionSource` interface.
  Tests: synthetic streams (jitter, stale fixes, accuracy rejects,
  pause/resume, kill mid-session → salvage file re-imports).
- [] slice 2 — Android session: manifest gains FOREGROUND_SERVICE,
  FOREGROUND_SERVICE_LOCATION, POST_NOTIFICATIONS (verify geolocator's
  merged service declaration at target API 34+); geolocator stream with
  ForegroundNotificationConfig + wake lock; Record action with the full
  permission flow, HUD chip, stop → unified import; action hidden where
  location support is unavailable (desktop). Manual verification per
  SPEC (screen-off session, recents-kill salvage).
- [] slice 3 — dashboard: follow-camera + course-up rotating marker during
  recording; stats panel (current/avg speed, distance, elapsed/moving
  time, altitude when reported); recording strings en+it + coverage test.
- [] slice 4 — robustness: startup salvage flow (notice + import of
  un-finalized GPX), battery-optimization exemption advisory in Settings
  (soft, no blocking dialogs), GPX writer↔reader round-trip fixture via
  the fixture tool.
- [] slice 5 — tilt (blocked upstream, re-verify API when it lands): adopt
  flutter_map pitch (`MapOptions.maxPitch`, gestures, follow-camera under
  pitch — fog circles/corridors are ground layers) when the pitch-support
  branch releases; owner call whether to track the unreleased branch
  earlier or wait. Fallbacks (maplibre_gl rewrite, mapigrade) are
  documented in the report but rejected meanwhile.
- [] backlog — desktop recording (needs a Linux location source), resume
  of a killed session, auto-pause-when-stationary, interval setting,
  vector-tiles/3D-building look (needs a new map-data decision).
- [] open decisions (report §Open questions): confirmed defaults — 1 s
  interval, soft battery advisory, mute-FGS when notifications denied,
  manual pause only, salvage-as-import. Still owner-side: pinch/early
  adoption of the flutter_map pitch branch (needs package-version
  sign-off).
