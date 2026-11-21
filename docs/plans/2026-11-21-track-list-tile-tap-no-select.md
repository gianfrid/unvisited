Implements: —

# Track list tile: tap = camera jump only; the checkbox is the only toggle

Revision of 2026-11-21-track-list-tap-fits-track.md after feedback: the
tile tap must not select the aggregate either.

## Behavior

- Tapping a track tile — the name **or the row below it** — jumps the
  camera to that track's own points. Nothing else.
- Selecting/deselecting is done **only** via the checkbox, which keeps
  controlling visibility; no other element in the tile toggles anything.

## Changes

- `lib/ui/app_model.dart` — `selectAndFitTrack` becomes `fitTrack`: only
  the per-track fit request (`fitTrackId` + epoch bump); no
  `selectedAnchor` write, no aggregate lookup.
- `lib/ui/track_list.dart` — the tile becomes a plain `ListTile` with
  `onTap: fitTrack` (name and subtitle row both hit it),
  `trailing: Row(Checkbox, ⋮ menu)`. A `CheckboxListTile` could not be
  used: it wires the whole tile to the checkbox's toggler, so no tap
  could ever mean anything else.
- Tests — unit: `fitTrack` sets the request, no selection side effect,
  hidden track no-ops; widget: one tap on name or subtitle zooms in,
  selection bar stays hidden, track stays visible.

## Verification

`flutter analyze` clean, `flutter test` green.
