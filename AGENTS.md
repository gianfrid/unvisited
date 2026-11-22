# Unvisited — Agent Guide

A Flutter app (Android-first, desktop Linux for development) that imports GPS tracks and plots them, fog-of-war style, on one OSM map. Read SPEC.md before any change; read ARCHITECTURE.md before structural or cross-component changes.

## Commands

Use `flutter`, not bare `dart`, for project commands (the `dart tool/*.dart` scripts named below are the exceptions):

- `flutter pub get`
- `flutter analyze` — must be clean before finishing a slice
- `flutter test`
- `flutter run -d linux`

## Non-discoverable gotchas

- Import parsing is pure Dart behind the `TrackParser` interface; keep it decoupled from UI widgets; a Rust FFI core is planned behind the same interface.
- Format detection is content-based (magic bytes / root element), never by extension; priority GPX, FIT, KMZ, TCX (plain KML alongside KMZ).
- FIT: key off the File Id message type (4 = activity, 32 = monitoring), never filename or folder path; skip monitoring files; tolerate truncated files and Smart Recording.
- Byte-identical re-imports dedup by 64-bit FNV-1a content hash (id = hash); cross-format rules are in SPEC.md.
- Data is local only; no network calls beyond OSM tiles; JSON index by design, no database.
- Ask before adding packages beyond: `flutter_map` + `latlong2`, `file_picker`, `xml`, `archive`, `geolocator`, `flutter_compass`.
- Desktop has no location plugin, so recording is Android-only; recording start is never background-initiated and never uses background-location permission.
- Never hand-edit binary fixtures or icons; regenerate fixtures with `dart tool/make_fixtures.dart`; edit `assets/icon/icon.svg`, then run `dart tool/make_icons.dart`.

## Workflow

Load the `todo-plan-workflow` skill before any non-trivial change — it is installed globally at `~/.vibe/skills/todo-plan-workflow/` and defines the backlog, plan files, the confirmation gate before write actions, the trivial fast-lane, immutable plan records, and commit rules. In this repo the backlog is `TODO.md` and plans live at `docs/plans/<date>-<slug>.md`. One project-specific line: `tool/build_release_apk.sh` is run only when explicitly asked, never automatically after commits; it runs detached in the background and must never block the prompt.

## Scope boundary

Nothing beyond SPEC.md's scope without agreement: no route planning, no turn-by-turn navigation, no per-service integrations, no cloud, no accounts.
