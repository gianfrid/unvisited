# Implement plain KML support in the app's import pipeline

## Findings (read-only investigation)

- `KmlParser` already exists (`lib/import/kmz_parser.dart:155`) and is in
  `TrackImporter`'s *default* parser list — but the app never uses that
  default: `TrackStore` (`lib/storage/track_store.dart:291-299`) wires an
  explicit list `[GpxParser(), FitParser(), KmzParser(), TcxParser()]` with no
  `KmlParser`, so plain KML is rejected as "unrecognized track format".
- The file picker already allows `.kml` (`import_coordinator.dart:259`) and
  the Android share-intent filter already accepts
  `application/vnd.google-earth.kml+xml` (AndroidManifest.xml:52); the SAF
  folder scan passes every file to the sniffer since the extension pre-filter
  was removed. So the one-line wiring fix covers all three import paths.
- Format priority stays GPX > FIT > KMZ > TCX > KML (KML sniffing is
  `<kml` in the XML head; last position is safest and matches the default
  list).

## Changes

1. **Code**: `lib/storage/track_store.dart` — add `KmlParser(KmzParser())`
   after `TcxParser()` in the wired parser list (import already present).

2. **Fixture**: `tool/make_fixtures.dart` — extract the OpenTracks KML text
   into `opentracksKml()`, have `opentracksKmz()` zip it, and also write
   `test/fixtures/afternoon_ride.kml`. Regenerate with
   `dart tool/make_fixtures.dart`; if the KMZ fixture churns only in its zip
   timestamp (known caveat), keep the committed KMZ byte-identical.

3. **Tests**:
   - `test/track_importer_test.dart` — detect the `.kml` fixture as KML;
     content-wins-over-extension case (KML bytes named `.gpx`); update the
     priority group title; add a TrackStore round-trip test importing
     `afternoon_ride.kml` through `store.importBytes` (regression test for
     the wiring bug).
   - `test/kmz_parser_test.dart` — `KmlParser.accepts` accepts KML XML and
     rejects GPX/ZIP; parse the new fixture (name, point count, lon/lat
     order).

4. **Docs** (re-add what the last cleanup removed, now true):
   - README.md formats line: `KMZ` -> `KMZ/KML`.
   - SPEC.md item 2 and the manual verification list: include KML.
   - AGENTS.md priority line: `(plain KML alongside KMZ)`.
   - ARCHITECTURE.md: kmz_parser bullet and the format-priority line.

## Verification

- `flutter analyze` clean, `flutter test` passes.
- Commit PLAN.md + code + tests + fixture + docs in one commit.
