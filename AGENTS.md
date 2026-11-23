# Unvisited — Agent Guide

A Flutter app (Android-first, desktop Linux for development) that imports GPS tracks and plots them, fog-of-war style, on one OSM map. Read SPEC.md before any change; read ARCHITECTURE.md before structural or cross-component changes.

## Commands

Use `flutter`, not bare `dart`, for project commands (the `dart tool/*.dart` scripts named below are the exceptions):

- `flutter pub get`
- `flutter analyze` — must be clean before finishing a slice
- `flutter test` — the default run is offline and deterministic
- `flutter test --dart-define=TILE_SERVER_TESTS=true` — opt-in live tile-server checks; do not remove the skip in a normal run
- `flutter run -d linux`

## Non-discoverable gotchas

- Import parsing is pure Dart behind the `TrackParser` interface, decoupled from UI widgets; a future Rust FFI core must sit behind the same interface.
- Format detection is content-based (magic bytes / root element), never by extension; priority GPX, FIT, KMZ, TCX (plain KML alongside KMZ).
- FIT: key off the File Id message type (4 = activity, 32 = monitoring), never filename or folder path; skip monitoring files; tolerate truncated files and Smart Recording.
- Re-import dedup: byte-identical files dedup by 64-bit FNV-1a content hash (id = hash); cross-format dedup requires BOTH start time within ±2 s AND total distance within 10% — either signal alone never dedups (see SPEC.md).
- Recording is state, not a second storage path: the staging GPX finalizes through the unified pipeline; never add a parallel catalog or a second track format.
- Recording starts only from the foreground Record action; never request `ACCESS_BACKGROUND_LOCATION`; never start the location service from the background.
- At standstill Android delivers `bearing = 0.0` (not null) — treat it as an unknown sentinel and do not feed it into course-up or the recording marker (see SPEC.md).
- Road attribution is intentionally sticky — the previously matched way wins while a rival stays within ~5 m; do not "simplify" it to nearest-way (justification in SPEC.md).
- Data is local only; no network calls beyond OSM/CyclOSM tiles; JSON index by design, no database package.
- Ask before adding packages beyond: `flutter_map` + `latlong2`, `file_picker`, `xml`, `archive`, `geolocator`, `flutter_compass`.
- Do NOT add `dart_osmpbf`: it pins `archive ^3.6.1`, conflicting with the app's `archive` v4 — the road build CLI's PBF reader is hand-written in `tool/` for this reason.
- No hardcoded user-visible strings: every string comes from `lib/l10n/app_strings.dart` in every supported language (currently English and Italian), and untranslated strings fail the tests; model/state classes never build user-facing sentences.
- Never hand-edit generated assets: fixtures via `dart tool/make_fixtures.dart`; icons by editing `assets/icon/icon.svg`, then `dart tool/make_icons.dart` (needs an external SVG renderer; never add a rasterizer to app dependencies).
- Desktop Linux has no location plugin: the Record action is hidden there; recording is Android-only.

## Workflow

Load the `todo-plan-workflow` skill (installed at `~/.vibe/skills/todo-plan-workflow/`) before any non-trivial change — it defines the backlog, plan files, the confirmation gate before write actions, the trivial fast-lane, immutable plan records, and commit rules. In this repo the backlog is `TODO.md` and plans live at `docs/plans/<date>-<slug>.md`. `tool/build_release_apk.sh` runs only when explicitly asked, never automatically after commits; it runs detached in the background and must never block the prompt.

## Scope boundary

Nothing beyond SPEC.md's scope without agreement: no route planning, turn-by-turn navigation, per-service integrations, cloud, accounts, or vector-tile map sources without an explicit decision; desktop recording stays in the backlog.
