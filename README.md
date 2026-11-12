# Unvisited

A Flutter app that imports GPS tracks from multiple sources — OpenTracks exports, Garmin FIT files, Strava exports — and plots all of them together on one OpenStreetMap-based map. A companion to recording apps; it does not record activities itself.

Supported track formats: **GPX**, **FIT** (activities only — monitoring files are skipped), **KMZ/KML**, **TCX**. Imports go through one unified, content-based pipeline; extension never decides the format.

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
├── import/                  # one unified import pipeline
│   ├── track_parser.dart     #   TrackParser interface + content sniffing helpers
│   ├── track_importer.dart  #   orchestrates detection and parsing
│   ├── gpx_parser.dart / tcx_parser.dart   # XML-based formats
│   ├── fit_parser.dart      #   pure-Dart FIT decoder
│   └── kmz_parser.dart      #   ZIP container → KML coordinate path
├── models/track.dart        # TrackData model
├── storage/track_store.dart # app-private track files + index.json catalog
└── ui/                      # app_model, map_page, track_colors
test/                        # unit tests, fixtures in test/fixtures/
tool/make_fixtures.dart      # regenerates binary FIT/KMZ fixtures
```

## Quick test on desktop Linux (no phone needed)

```bash
flutter pub get
flutter run -d linux
```

The import pipeline, track store and map render identically to Android, so this is the supported way to quick-test without a smartphone.

Import tracks with the **Import** button (file picker, supports multiple files) or the folder button above it (imports recursively, e.g. a `GARMIN/Activity/` folder). Tracks and the catalog are stored under `$XDG_DATA_HOME/unvisited` (default `~/.local/share/unvisited`) and survive restarts. Deleting that directory resets the app state.

Re-importing a byte-identical file does not create a duplicate — tracks are deduplicated by content hash.

## Run on Android

```bash
flutter devices          # plug in a phone with USB debugging, or start an emulator
flutter run -d <device>  # or just: flutter run
```

On Android you get everything the desktop has, plus:

- **Folder import via SAF** — pick any folder (e.g. a watch mounted over USB-OTG); every supported file below it is imported.
- **Share intents** — share a track from OpenTracks, a file manager, etc. directly into Unvisited.

Build an APK:

```bash
flutter build apk --debug     # build/app/outputs/flutter-apk/app-debug.apk
```

## Tests

```bash
flutter test       # all parsing/storage logic is pure Dart, covered by unit tests
flutter analyze
```

- Desktop dev runs resolve the build time (shown at the bottom of the track drawer) from the latest git commit automatically. To bake it into an APK build: `flutter build apk --dart-define=BUILD_TIME=$(git log -1 --format=%cI)`.

Details on the testing strategy, conventions and the rules that govern changes are in [SPEC.md](SPEC.md); how the pieces fit together is in [ARCHITECTURE.md](ARCHITECTURE.md).
