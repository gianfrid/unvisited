# Unvisited — Specification

The rules: scope, invariants, testing, conventions and acceptance criteria. How to run the app is in [README.md](README.md); how it is built is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Scope (MVP)

1. Import tracks from local files via Storage Access Framework (SAF) folder access and share intents (Android) or file/folder pickers (desktop). No per-service integrations, no cloud, no backend, no accounts.
2. Format priority, in order: GPX first (universal), then FIT, then KMZ, then TCX (plain KML is handled alongside KMZ — OpenTracks exports both). All sources flow through one unified import pipeline.
3. Persist imported tracks locally as files under an app-private storage root; catalog metadata lives in a JSON index (`index.json`) next to a `tracks/` directory. No database package.
4. Show every imported track together on a single map using OpenStreetMap-based tiles, with a selectable base style in Settings: standard OSM raster (default) or CyclOSM. Both are ODbL data; attribution rides with the tiles (the standard notice, plus OpenStreetMap France for CyclOSM) and is shown on the map.
5. The map shows an exploration overlay in fog-of-war style: every track point unlocks the area around it (15 m radius circles drawn translucently over the tiles, which stay a fully legible map), and a section of an OSM road/trail that runs close to unlocked points is matched and unlocked with it. Road matching is offline and decided (research: `docs/offline-road-matching-for-unvisited-research-report.md`): road data comes from a Geofabrik extract filtered to `highway=*` ways, preprocessed on the desktop into a flattened, spatially bucketed file (varint polylines + JSON sidecar) that the user side-loads into the app — nothing road-related is bundled or fetched at runtime. Matching is geometric (point-to-segment within the ~15 m unlock radius against the same cell coalescing the circles use), per-segment: only the sub-length of a way actually walked unlocks, a way is flagged complete at ≥90% matched length. Attribution is sticky (hybrid scoring, measured 2026-11-14): each unlock center's coverage is credited to one way — the previously matched way while any rival stays within a ~5 m switch margin of the nearest candidate, else the nearest way — so GPS wobble between parallel ways (400+ attribution hops across 24 real recordings) cannot let an un-ridden parallel way complete on wobble alone. No Overpass, no routing graph, no HMM. ODbL attribution is covered by the existing OSM notice.
6. Active recording (Android, decided — research: `docs/active-recording-for-unvisited-research-report.md`): a Record action starts a foreground-service GPS session and shows a live dashboard (speed, distance, duration/moving time; follow-camera), staging the points into a GPX file that finalizes on stop through the same unified import pipeline as any other source — recorded tracks are ordinary catalog tracks. While a session runs the Record button (in the cluster on the edge opposite the map's control pill) becomes Pause, and once paused Resume with Stop above it; Stop asks the track's name (default: the current date-time timestamp) and finalizes under it. The dashboard renders 2D: the map stays north-up by default while recording, and Settings → "Rotate map while recording" (off by default) opts into the course-up follow-camera; the tilted map view is parked in the backlog pending upstream flutter_map pitch support. Desktop Linux cannot record (no location plugin there), so the Record action is hidden and desktop recording is backlog. The governing invariants are in [Recording](#recording) below; the design is in [ARCHITECTURE.md](ARCHITECTURE.md).

7. Track playback (delivered): the track list's ⋮ menu replays a stored track on the same map — a marker animates along the track's own timestamps at a controllable speed (1×–64×), riding the follow-camera the recording uses (shared module: identical glide, framing and release-on-gesture; the same `mapRotation` setting drives north-up/course-up). A replay is ephemeral presentation state: nothing persists, it never runs during a recording session (the menu gates starting one; starting a session stops a running replay), and a track without a timestamp span has no timeline to replay (entry disabled).

Out of scope: route planning, turn-by-turn navigation, per-service integrations, cloud sync, accounts, and (pending an explicit decision) any vector-tile map sources. Desktop recording stays in the backlog.

## Hard rules and invariants

### Privacy and network

- Data is local only. No cloud sync, no server component, no analytics.
- Never add network calls beyond fetching base map tiles (OSM standard raster or CyclOSM).

### Storage

- Catalog is a JSON index (`index.json`) by design — never add a database package.
- Track deduplication: byte-identical re-imports dedup by 64-bit FNV-1a content hash (id = hash). Cross-format activity dedup catches the same activity exported once as FIT and once as GPX: matching start time (±2 s) and total distance (within 10%) counts as a duplicate; either signal alone never dedups, and a track without a start time is only caught by the byte hash.

### Import pipeline

- Format detection is content-based (magic bytes / root element), never file extensions.
- Parsing logic is decoupled from UI widgets so it stays unit-testable against fixtures in `test/fixtures/`.

### FIT parsing rules

- Key off the FIT File Id message: type 4 = activity, type 32 = monitoring. Do not branch on filename or folder path.
- Skip `monitoring` FIT files (`GARMIN/Monitor/`, all-day health metrics). Naive "import every .fit" is wrong.
- Tolerate truncated FIT files (missing summary/session block, e.g. battery death mid-ride) and Smart Recording's variable intervals plus pause events.

### Recording

- A recording session is state, not a second storage path: its points stream into a staging GPX under the app root and finalize through the unified pipeline on stop (content-hash dedup and unlock matching apply unchanged). Never add a parallel catalog or a second track format.
- The session logic (`RecordingSession`, filters, GPX writer, stats) is pure Dart behind a `PositionSource` interface — no Flutter imports, unit-testable against synthetic position streams, Android-swappable like the parsers.
- Recording only ever starts in the foreground (Record action). Never request `ACCESS_BACKGROUND_LOCATION`; never start the location service from the background.
- Accept filters and staging semantics are part of the contract: fixes worse than the accuracy threshold (~50 m) are dropped, fixes whose implied displacement speed is an outlier (absolute cap, or above the recent speed window's median + k·MAD Hampel threshold) are dropped, flush cadence keeps the loss window bounded, pause/fix-loss resume as new `<trkseg>` breaks with one track per session.
- A fix below the session's moving-speed threshold (~0.5 m/s fused) reports no heading and holds the last known course: Android delivers `bearing = 0.0` (not null) at standstill, which is an "unknown" sentinel — feeding it into the course would point the recording marker and the course-up camera at noise on every stop.

## Testing strategy

- Implement in small vertical slices; each slice ends with unit tests against fixture files in `test/fixtures/`.
- All parsing/storage logic is pure Dart and covered by unit tests against those checked-in fixtures.
- Binary FIT/KMZ/PBF fixtures are generated by `dart tool/make_fixtures.dart` and committed; re-run the tool whenever a fixture must change.
- Road-format fixtures are synthetic (a handful of hand-made streets written by the same build tool), never a real Geofabrik extract; real extracts enter only through the CLI and are verified manually.
- App icons are generated from `assets/icon/icon.svg` by `dart tool/make_icons.dart` and committed; edit the SVG, never the generated PNG/ICO files. The tool needs an external SVG renderer (`cargo install resvg`, or `--renderer "npx --yes @resvg/resvg-js-cli"`) — it deliberately does not add a rasterizer to the app's dependencies.

```bash
flutter test       # unit tests (parsers, store, importer, model, map) — runs offline
flutter analyze    # must be clean
```

The live tile-server checks (`test/tile_server_test.dart`) hit the real OSM/CyclOSM endpoints and are opt-in so the default run stays offline and deterministic: `flutter test --dart-define=TILE_SERVER_TESTS=true`.

## Conventions

- Match the existing code style (indentation, naming, error handling density); minimal diffs.
- Keep parsing portable — not tied to Flutter. Any future Rust core (behind Dart FFI, flutter_rust_bridge) must sit behind the same `TrackParser` interface; the pure-Dart MVP parser implements compressed timestamps, chained headers, developer fields, little/big endianness and truncation tolerance.
- Ask before adding packages beyond the established set: `flutter_map` + `latlong2`, `file_picker`, `xml`, `archive`, `geolocator`, `flutter_compass`. No database — JSON index by design. Dev-only preprocessing for the desktop build CLI never ships in the APK and never touches runtime code; the road build CLI's PBF reader is hand-written in `tool/` (the `dart_osmpbf` package pins `archive ^3.6.1`, which conflicts with the app's `archive` v4) precisely so no new package dependency is needed.
- No user-visible text is hardcoded in widgets: every string comes from `lib/l10n/app_strings.dart`, in every supported language (currently English and Italian). Localization is hand-rolled rather than `flutter_localizations` + ARB — the whole UI is one screen's worth of strings — so adding a language means one `AppStrings` subclass, one entry in `AppStrings.supported` and one entry in `languageName`; the tests fail on any untranslated string. Model/state classes never build user-facing sentences (see `ImportSummary.describe`); they take the strings from the caller.

## Manual verification steps

Desktop Linux (no phone needed):

1. `flutter run -d linux`
2. Import GPX/FIT/KMZ/KML/TCX files via the Import button; verify they render on the map.
3. Import a folder (e.g. one containing `GARMIN/Activity/`) via Import → A folder; verify recursive import of all supported files.
4. Re-import the same file; verify no duplicate track appears (dedup by content hash).
5. Restart the app; verify tracks and catalog persist under `$XDG_DATA_HOME/unvisited`.
6. Delete that directory; verify the app starts empty.

Android:

1. `flutter run -d <device>` (or install the debug APK).
2. Fresh install first: before importing anything, verify the OSM map tiles render on the start view (no grey map).
3. Share a KMZ/GPX from OpenTracks via the share sheet; verify it imports.
4. Pick a folder via SAF (e.g. a watch mounted over USB-OTG); verify every supported file below it imports.
5. Repeat the dedup and persistence checks.
6. Recording: accept the location prompt from the Record action; verify the foreground-service notification appears, walk/bike a stretch with the screen off, verify the session kept recording (distance grows), then stop — the track appears in the catalog, shows in the fog overlay, and unlocks road corridors when a region file is active.
7. Kill the app mid-recording (swipe from recents): at next start the un-finalized recording is offered/imported as a partial track with a notice.

## Acceptance criteria

- All scope items (above) work on their target platforms: recording and its dashboard on Android, everything else on both Android and desktop Linux.
- Every supported source (OpenTracks, Garmin FIT, Strava GPX/FIT) flows through the unified pipeline and renders on the single OSM map.
- FIT activity files import; FIT monitoring files are skipped without error; truncated FIT files still import.
- `flutter analyze` is clean and `flutter test` passes.
- No network traffic beyond base map tiles (OSM standard, CyclOSM); no data leaves the device.
