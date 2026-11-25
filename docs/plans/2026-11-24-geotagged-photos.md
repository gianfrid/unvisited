# Geotagged photos: camera action, storage, markers, preview, reposition, Settings gate

Implements: TODO.md — "Optional geotagged photos" (units 1–6)

## Decisions (with the user, 2026-11-24)

1. **`image_picker`** launches the *system* camera app via intent. No
   `CAMERA` permission is declared in the manifest (Android requires it
   only when declared; image_picker's intent path works undeclared), so
   the "permission asked only on press" requirement is satisfied in the
   strongest form: pressing the button just opens the camera, no runtime
     prompt at all. Package addition approved by the user.
2. **Position = latest fix in hand**, no fresh GPS request at press time:
   the session's live fix while recording, else the latest fix obtained
   this run (the silent startup poll or a Locate). A stale fix is
   accepted; the position is **editable afterward** (unit 5) with a
   tap-to-move mode from the preview dialog (dragging would fight the
   map pan).
3. **App-private storage, not the gallery** (the user's question, answered
   with trade-offs and pending this review's confirmation): gallery
   storage via MediaStore would silently feed Google Photos auto-backup
   (breaks SPEC's local-only hard rule), leaves metadata orphaned by any
   gallery-side delete/clean, and needs host-channel code for `content://`
   reads in the preview. Instead the captured bytes are copied into
   `<app root>/photos/` exactly like track files live under `tracks/`;
   the preview is a plain `Image.file`. The user accepted the trade-off
   with an addition: the preview dialog offers **Save to gallery** and a
   generic **Share** action (unit 4) — explicit, user-initiated exports
   through the host channel (MediaStore insert / the already-declared
   FileProvider share intent), which keep the silent auto-backup
   concern out of the app's own capture path. No new packages.
4. **Settings switch hides everything but keeps storage**: camera button
   and map markers hidden while off; no file is ever deleted by the
   toggle. Default on. Android-only row (the recording-adjacent rows
   already use `Platform.isAndroid` so desktop widget tests never build
   it).
5. **Button placement**: in the record cluster (the edge opposite the
   control pill; left with the default settings) for symmetry with the
   other edge bar. Top-to-bottom `Camera`, `Stop`, `Record/Pause` — the
   Stop/Record pairing keeps its current shape. States: idle
   `[Camera][Record]`, running `[Camera][Stop][Pause]`. (The whole
   cluster already hides while a replay runs — the camera inherits that.)
6. **Desktop stays out**: the same gates as Record apply —
   `locationSupported` false hides the cluster outright, and no
   fix means no camera button.

## Unit 1 — Photo storage

- `lib/storage/track_store.dart`: `StoredPhoto` — `id` (FNV-1a content
  hash, the existing `contentHash`), `file` (relative to a new store
  `photosDir`, mirroring `tracksDir`), `lat`, `lon`, `takenAt` (UTC);
  `toMap`/`fromMap`, tolerant like `StoredTrack.fromMap` (a malformed
  entry or a missing file drops the photo, never startup). `TrackStore`:
  `photosDir`, `List<StoredPhoto> get photos`, `addPhoto(bytes,
  {lat, lon, takenAt})` (writes `photos/<hash>.jpg`; a byte-identical
  photo returns the existing entry unchanged), `updatePhotoPosition`,
  `removePhoto` (deletes file + entry), and `clearAll` extended to wipe
  `photos/` and its entries — delete-all is the "wipe exploration data"
  action. `_saveIndex` gains the `photos` list (written only when
  non-empty, like `unlockedWays`); `load` reads it tolerantly and skips
  entries whose file is gone. Catalog export/import zips stay
  track-only (v1; documented).
- Tests: new `test/photo_store_test.dart` (temp dir) — add/remove/
  update-position, duplicate bytes return the existing entry, missing
  file tolerated on load, `clearAll` removes photos, index round-trip.

## Unit 2 — Capture seam + save pipeline

- `flutter pub add image_picker` (user-approved).
- `lib/photos/photo_source.dart`: pure port —
  `abstract class PhotoSource { Future<PhotoCaptureOutcome> capture(); }`
  with a sealed outcome (`PhotoCaptureSucceeded(bytes)` /
  `PhotoCaptureDeclined` / `PhotoCaptureFailed(reason)`) — the
  `PositionSource` pattern: the model stays testable, no platform code
  in tests. Impl `lib/photos/image_picker_source.dart` wraps
  `ImagePicker().pickImage(source: ImageSource.camera)` and reads the
  returned `XFile` bytes; only constructed on Android.
- `lib/ui/app_model.dart`: the model owns a `PhotoSource` injected via
  constructor (needed by widget tests too, test/helpers.dart);
  `AppModel.takePhoto()` → capture → `store.addPhoto` at the freshest
  fix (`recorder`'s session fix when `isRecording`, else the page's
  latest fix passed in by the caller) → `notifyListeners`; returns the
  outcome so the UI can toast "saved"/"declined". Photos ride one
  model notification: the marker layer is static state (like tracks),
  no live channel needed.
- Tests: `test/app_model_test.dart` (or a new `test/photo_capture_test`)
  — fake source feeding bytes into a temp store: success stores + a
  duplicate outcome; declined adds nothing.

## Unit 3 — Camera button

- `lib/ui/map_controls.dart`: `RecordCluster` gains a camera
  `HeaderAction` (top slot; `Camera` / `Stop` / `Record`), gated on a
  new `photoPositionAvailable` flag + `model.photosEnabled`. Tap → the
  page's `_takePhoto` (below). Capture failure/decline → `showMapToast`
  (no dialog); success → toast "Photo added" (the camera app returns to
  the map after the shot, so feedback matters).
- `lib/ui/map_page.dart`: a `_latestFix` field (set by
  `_silentPositionUpdate` and `_locate`, never dropped — distinct from
  `_locatedPosition`, which the pan-drop rule clears); the camera's
  position is the session fix when recording, else `_latestFix`. While
  `_takePhoto` is in flight the button shows its disabled state
  (image_picker returns after the camera app closes).
- `lib/l10n/app_strings.dart`: `cameraLabel`, `cameraTooltip`,
  `photoAdded`, `photoDeclined`, `photoFailed` (en + it; the coverage
  test pins both languages).
- Tests: `test/map_page_test.dart` — button hidden without
  `locationSupported`, hidden before the first fix, visible after;
  fake source captures → toast; declined → no store entry.

## Unit 4 — Photo markers and preview

- `lib/ui/map_page.dart`: `MarkerLayer` of photo pins (camera glyph in a
  surface disc, the recording marker's look), above the corridors and
  below the "you are here"/recording markers; gated on the setting;
  stays mounted during recordings and replays. Tap detection via the
  marker's own button → preview dialog.
  `FlutterMap.onTap` is unchanged (cluster taps win).
- Preview dialog (`showDialog` in the page or a small
  `lib/ui/photo_preview.dart`): `Image.file` scaled to fit, taken-at date
  as caption, actions Close / Reposition (unit 5) / Delete — Delete is
  two-step like the stop-discard confirm — plus **Save to gallery** and
  **Share** (user-added scope): two host-channel methods on
  `unvisited/host` (MediaStore insert for self-created media — no runtime
  permission on API 29+ — and an `ACTION_SEND` share via the existing
  FileProvider authority). Desktop falls back to the channel-missing
  convention; both are Android-only UI, hidden off-Android. Deletion
  goes through the model → store; the dialog's effects ride the model
  notification.
- Strings: `photoDelete`, `photoDeleteConfirmTitle`, `photoTakenAt(date)`,
  `photoSaveToGallery`, `photoSaveToGalleryDone`, `photoShare`
  (en + it).
- Tests: marker visible per setting gate; tap opens the preview with
  `Image` present; Delete asks then removes the entry.

## Unit 5 — Reposition

- Preview's Reposition action closes the dialog and arms page state
  `_repositioningPhoto`; a one-line banner (the `EmptyHint` slot, top
  center) "Tap where the photo was taken" with a Cancel action;
  `FlutterMap.onTap` checks reposition mode *before* aggregate selection,
  so the next map tap sets the photo's position (nearest-tap wins, the
  aggregate-selection tolerance does not apply) and re-arms selection.
- Strings: `photoReposition`, `photoRepositionHint`, `cancel` (en + it).
- Tests: previews → Reposition → map tap updates coordinates (store +
  marker move); Cancel restores the interaction mode.

## Unit 6 — Settings + docs

- `AppSettings`: `photos` (default true) + `savePhotosOn` through the
  model, the usual `_apply` pattern; `SettingsSheet` row (Android-only,
  above the battery row) — switch label "Photos", subtitle says photos
  and markers hide while it's off, stored photos are kept.
- Docs: SPEC scope item 8 (photos: camera button, latest-fix tagging,
  preview + reposition, disable switch; no new permission, local-only
  storage rationale), Testing/manual-verification-step "press Camera →
  take a photo → marker appears → preview → reposition" ; ARCHITECTURE
  UI + storage paragraphs (`photos/`, `StoredPhoto`);
  README short bullet. NOTE in plan/commit messages: no manifest change
  is needed or wanted — declaring `CAMERA` would *break* image_picker's
  undeclared-intent path.
- Tests: settings row (Android-only not buildable in desktop tests —
  test the model/store persistence), toggle hides markers + button in
  widget tests with the setting forced.

## Verification per unit

`flutter analyze` clean, `flutter test` green; the unit's TODO line is
removed in the same commit that ships it (the parent entry survives
until unit 6), plan committed with unit 1.
