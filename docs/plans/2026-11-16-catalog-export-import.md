# Whole-catalog export/import (one zip in, one zip out)

Implements: —

## Scope

Settings gains "Export all tracks" (writes `unvisited-export-<date>.zip`
containing `index.json` + `tracks/*`, via FilePicker.saveFile, compressed
with the already-bundled `archive` package) and "Import from export"
(picks a zip, validates it, and re-imports every track file inside
through the unified pipeline — so content-hash dedup, fog and road
matching apply unchanged; a re-import of the same export adds nothing).
Per-track export stays as is. The side-loaded roads file is not part of
the export (it is a user-provided region file, re-chosen in Settings).

## Plan

1. `lib/storage/track_store.dart`: `exportCatalogBytes()` builds the zip
   (index.json + every file under tracks/), `importCatalogBytes()`
   unpacks to a temp dir, sanity-checks index.json presence, and feeds
   each track file through `importBytes` (the unified pipeline).
2. `lib/ui/app_model.dart`: `exportCatalog()` / `importCatalog()` wrappers
   returning a summary (counts) for the toast; FilePicker save/pick
   handled in the UI layer like the existing per-track export.
3. `lib/ui/settings_sheet.dart`: two ListTile entries with en+it strings
   (pinned in app_strings_test), toasts on success/failure.
4. Tests: round-trip — import fixtures, export, fresh store, import the
   zip, same track ids/points; re-importing the same zip dedups to zero
   new tracks. Strings parity test updated.
5. Verify: `flutter analyze` clean, `flutter test` passes; commit plan +
   change together.
