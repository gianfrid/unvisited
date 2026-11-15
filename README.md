# Unvisited

A Flutter app that imports GPS tracks from multiple sources — OpenTracks exports, Garmin FIT files, Strava exports — and plots all of them together on one OpenStreetMap-based map, as a fog-of-war exploration overlay: the places your tracks pass through show up as unlocked corridors, the rest of the map stays untouched. Active recording (Android): one Record action turns the map into a ride/walk dashboard — live speed, distance, duration, follow-camera with course-up — that pauses, resumes, and on stop asks the track's name before writing an ordinary GPX track into the same catalog.

Supported track formats: **GPX**, **FIT** (activities only — monitoring files are skipped), **KMZ/KML**, **TCX**. Imports go through one unified, content-based pipeline; extension never decides the format.

The map's base style is selectable in Settings → Map layer: the standard OSM raster or **CyclOSM** (a cycle-focused style from OpenStreetMap France, same ODbL data).

The interface is available in **English** and **Italian**. By default it follows the system language (falling back to English for anything else); Settings → Language switches it, and the choice is remembered.

How this project is documented:

- [README.md](README.md) — what the app is and how to run it (this file)
- [ARCHITECTURE.md](ARCHITECTURE.md) — system overview, components, data flow, tech choices
- [SPEC.md](SPEC.md) — scope, hard rules and invariants, testing, conventions

## Project layout

```
lib/
├── main.dart                # entry point
├── host_channel.dart        # Android host channels (storage root, SAF, share intents)
├── tile_source.dart         # OSM tile provider
├── geo.dart                 # shared geodesy (haversine distance, bearing)
├── build_version.dart       # the git-derived About build time
├── aggregate/               # union-find clustering of visible tracks into aggregates
├── import/                  # one unified import pipeline
│   ├── track_parser.dart    #   TrackParser interface + content sniffing helpers
│   ├── track_importer.dart  #   orchestrates detection and parsing
│   ├── gpx_parser.dart / tcx_parser.dart   # XML-based formats
│   ├── fit_parser.dart      #   pure-Dart FIT decoder
│   └── kmz_parser.dart      #   ZIP container → KML coordinate path
├── recording/               # active-recording engine (Android), pure Dart
│   ├── position_source.dart #   the platform seam geolocator plugs into
│   ├── android_position_source.dart   # geolocator implementation
│   ├── recording_session.dart  # state machine, filters, distance/speed stats
│   └── staging_gpx.dart     # incremental GPX writer + crash salvage
├── road/                    # offline road matching (side-loaded region files)
│   ├── road_format.dart     #   the .unvisited-roads container, polyline5 encoding
│   ├── road_store.dart      #   lazy z12-bucket reader with an LRU
│   ├── road_matcher.dart    #   geometric matching against unlock centers
│   └── road_bench.dart      #   profiling (desktop CLI + profile-mode in-app run)
├── l10n/app_strings.dart    # every user-visible string, English + Italian
├── models/track.dart        # TrackData model
├── storage/track_store.dart # app-private track files + index.json catalog
└── ui/                      # app_model + its import_coordinator / recording_controller
                              # / recording_live concerns, map_page and the modules it
                              # composes (map_actions, zoom_slider, format, stats_panel,
                              # settings_sheet, track_list, fog_of_war, track_colors)
test/                        # unit tests, fixtures in test/fixtures/
assets/icon/icon.svg         # the app icon (source of truth)
tool/make_fixtures.dart      # regenerates binary FIT/KMZ/PBF test fixtures
tool/make_icons.dart         # regenerates every platform icon from the SVG
tool/build_roads.dart        # builds .unvisited-roads road files (PBF or JSON ways in)
tool/pbf_reader.dart         # hand-written OSM PBF reader for the build CLI
tool/bench_roads.dart        # benchmarks the road parse/match pipeline
```

## Prerequisites

Building and running the app needs only a Flutter SDK (3.47+, Dart 3.13+) and, for Android, the Android SDK — `flutter doctor` tells you what is missing. Nothing else is required: `flutter pub get && flutter run -d linux` (or `flutter run` on a device) is the whole setup, and the app's icons and test fixtures are committed.

Two optional tools regenerate committed files. Neither is needed to build or run the app — only when the source they derive from changes:

| Tool | Needed when | Requires |
|---|---|---|
| `dart tool/make_icons.dart` | `assets/icon/icon.svg` changes | An SVG renderer: `cargo install resvg`, or `npx --yes @resvg/resvg-js-cli` (passed with `--renderer`) |
| `dart tool/make_fixtures.dart` | test fixtures change | Nothing beyond the project's own dependencies |

The icon tool deliberately does not pull a rasterizer into the app's dependencies, so it shells out to one instead; without it on `PATH` it fails with the install commands to run.

## Quick test on desktop Linux (no phone needed)

```bash
flutter pub get
flutter run -d linux
```

The import pipeline, track store and map render identically to Android, so this is the supported way to quick-test without a smartphone.

Import tracks with the **Import** button: it offers **Track files** (the file picker, supports multiple files) and **A folder** (imports recursively, e.g. a `GARMIN/Activity/` folder). Tracks and the catalog are stored under `$XDG_DATA_HOME/unvisited` (default `~/.local/share/unvisited`) and survive restarts. Deleting that directory resets the app state.

The current build installs a user-local desktop entry plus the 256px hicolor icon (skip with `-DINSTALL_DESKTOP_FILES=OFF`): on GNOME the dash icon is resolved by matching the app id against that entry, since GTK's Wayland backend cannot set the window icon at all. The same entry is manageable by hand: `linux/desktop-entry.sh install` points `Exec` at a built bundle, so the app launches from the overview grid too (`uninstall` reverses it; a rebuild resets the entry back to its committed `Exec`).

Re-importing a byte-identical file does not create a duplicate — tracks are deduplicated by content hash.

## Run on Android

```bash
flutter devices          # plug in a phone with USB debugging, or start an emulator
flutter run -d <device>  # or just: flutter run
```

On Android you get everything the desktop has, plus:

- **Folder import via SAF** — pick any folder (e.g. a watch mounted over USB-OTG); every supported file below it is imported.
- **Share intents** — share a track from OpenTracks, a file manager, etc. directly into Unvisited.
- **Recording** — a Record action starts a foreground-service GPS session and a live dashboard (speed, distance, duration/moving time; follow-camera with the map rotated to the course, screen-on latch), staged as a GPX that finalizes into the same catalog as any import, under the name the stop dialog proposes (a date-time timestamp, editable). A killed session is salvaged as a partial track at next start; a tilt/3D map view is excluded (backlog, pending flutter_map pitch support). Desktop cannot record — desktop Linux has no location plugin — so the action is hidden there (desktop recording is backlog).

Build an APK:

```bash
flutter build apk --debug     # build/app/outputs/flutter-apk/app-debug.apk
```

## Road data files (optional)

Road matching works on one side-loaded region file; nothing road-related is bundled with the app or fetched at runtime. Build one from any Geofabrik extract on the desktop:

```bash
osmium tags-filter region.osm.pbf w/highway -o roads.osm.pbf   # optional pre-filter
dart run tool/build_roads.dart roads.osm.pbf region.unvisited-roads
```

The build CLI also accepts the unfiltered extract directly (its own reader drops everything without a `highway` tag); the osmium filter only makes the build faster and the intermediate file smaller. All `highway=*` classes are in scope. ODbL attribution is covered by the app's existing OSM notice.

Load the built file via Settings → Road data: it is copied into the app's private storage and stays active there (swapping regions re-runs matching for the stored tracks, and removing the file never erases unlocked corridors — the overlay reads its data from the catalog, not the region file).

## Tests

```bash
flutter test       # all parsing/storage logic is pure Dart, covered by unit tests (runs offline)
flutter analyze
```

The live tile-server checks (`test/tile_server_test.dart`) are opt-in so the default run stays offline: `flutter test --dart-define=TILE_SERVER_TESTS=true`.

- The build time (shown in Settings → About) is the latest git commit's time: desktop dev runs read it from the checkout at runtime, and APK builds bake it automatically via gradle (`flutter build apk` needs no extra flags). A `BUILD_TIME` dart-define overrides both.

Details on the testing strategy, conventions and the rules that govern changes are in [SPEC.md](SPEC.md); how the pieces fit together is in [ARCHITECTURE.md](ARCHITECTURE.md).
