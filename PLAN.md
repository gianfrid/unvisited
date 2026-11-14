# Slice 13 — deleting a track asks for confirmation

## Context

A drawer swipe (`Dismissible`, end-to-start) or the delete `IconButton`
calls `model.delete(track)` directly — one accidental swipe destroys the
track (the file goes with it). Both paths must pass through a
confirmation dialog that names the track.

## Steps

1. `lib/l10n/app_strings.dart` — dialog strings, both languages:
   - `deleteConfirmTitle(trackName)` — "Delete `name`?" / "Eliminare `name`?";
   - `deleteConfirmBody` (en: "The track file is deleted with it. This
     cannot be undone." / it equivalent);
   - `deleteConfirmGo` (en "Delete", it "Elimina") and a "Cancel"
     ("Annulla") — cancel reuses no existing getter, so add one.
2. `lib/ui/map_page.dart` — `_TrackTile` gains a `_confirmDelete(model,
   track, strings)` helper: `showDialog` with the strings above; only on
   confirm, `model.delete(track)` runs. Both the `Dismissible`
   `onDismissed` and the `IconButton` call the helper. Because the
   dialog lives above the drawer, use the root navigator context
   carefully: after the dialog closes the drawer may also need closing —
   keep it simple, leave the drawer open (delete updates the list live).
   A cancel (or bar dismissal) is a pure no-op.
3. Widget tests (`test/map_page_test.dart`):
   - swipe the tile → dialog appears naming the track; "Cancel" → the
     track and its file survive;
   - swipe again → "Delete" → track gone from the catalog and disk;
   - the tile's delete button opens the same dialog.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 13 TODO entry; PLAN.md
  carries over to the next task unmodified.
