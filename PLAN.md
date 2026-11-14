# Plan — track list catalog UX (TODO.md "Track list", units 1–5)

Five vertical slices; each ends with tests and a commit. New strings ship
en + it with their slice; `app_strings_test.dart`'s coverage table grows in
step.

## Slice 1 — the ⋮ menu (unit 1)

`lib/ui/track_list.dart` `_TrackTile`: replace the trailing delete
IconButton with a ⋮ (`Icons.more_vert`) opening a `PopupMenuButton<String>`
with Info / Delete / Export. Delete routes through the existing
confirmation dialog (`_confirmDelete`); swipe-to-delete untouched.

Menu strings: `trackMenuTooltip` ('Track actions'), `trackMenuInfo`,
`trackMenuExport` ('Export'), reuse `deleteTrack` for Delete.

Widget tests: menu opens on tap; Delete tap shows the existing confirm
dialog; every tile still toggles visibility via the checkbox.

## Slice 2 — the info dialog (unit 2)

`showDialog` from the Info menu entry: name (title), start date/time
(model locale-formatted), format, point count, distance, duration,
average speed — distance over duration, '—' when either is missing
(never a fabricated 0). Reuse the shared `formatDistance`/
`formatDuration`; date/time formatting must not hand-roll — use the
existing pattern in `app_strings.dart` (parameterized getters only; the
strings class never computes). New strings: `infoTitle(start)` (or plain
'Info'), `infoPoints`, `infoDistance`, `infoDuration`, `infoAvgSpeed`,
`infoStart`.

Widget test: from a fixture-imported catalog, open Info and find every
field rendered; empty-duration track shows '—'.

## Slice 3 — export (unit 3)

- **Desktop Linux**: `FilePicker.saveFile` (already a dependency) → copy
  the stored file's bytes as-is to the returned path. Toast the result.
- **Android**: new host-channel method `shareTrack(path, mime)` in
  `MainActivity.kt` — an ACTION_SEND Intent fed by a `FileProvider`
  (androidx.core is already in the app via Flutter embedding; add the
  `file_paths.xml` + provider in the manifest). No new pub package.
  Files live under the app-private storage root, so the provider scopes
  exactly there.
- **Model**: `ImportCoordinator` gains
  `Future<String?> exportTrack(StoredTrack)`? No — export is UI glue:
  put `exportTrack` on `AppModel` reading `store.trackFileFor(track)`
  (a small accessor if the store doesn't expose one) and delegating to
  the host channel / FilePicker per platform.
- Strings: `exportDone` / `exportSuccess`, `exportFailed`, en + it.
- Widget tests: menu Export tap invokes the platform glue (mocked host
  channel answers, like the existing geolocator mocks); cancellation
  imports/re-exports nothing.

## Slice 4 — aggregated tile colors (unit 4)

`_TrackTile` gains a leading color dot rendered in the track's
aggregate's resolved tint — read from the existing
`model.aggregateTintKeys` (palette rank or override, exactly what the map
draws), falling back to the default tint for hidden-but-listed tracks.
The checkbox and subtitle stay as they are.

Model note: `aggregateTintKeys`/`aggregates` are built from
`visibleTracks`; the list shows all tracks (including hidden) — hidden
tracks fall back to the default tint (they leave no aggregate until
re-shown).

Widget tests: single track → default tint dot; tracks that cluster show
the same color dot; (later) an override set via selection reflects in the
list.

## Slice 5 — tap a tile to fit its aggregate (unit 5)

Tapping the tile body (not the checkbox, not the ⋮ menu): selects the
track's aggregate (sets `selectedAnchor`) and asks the map to fit it — a
`fitRequestEpoch` bumped on the model; `MapPage._onModelChanged` already
compares import epochs the same way and gains the same handling for fit
requests, fitting the selected aggregate's points via `_fitWhenSized`.
The selection bar appears as a side effect (consistency: the user can
immediately hide/recolor the aggregate).

Widget tests: tap fits (camera center/zoom change to cover the
aggregate) and the selection bar appears.

## Order and commits

Slices 1–5, each committed with PLAN.md current state and the TODO.md
unit removed. `flutter analyze` clean + `flutter test` green per slice.
