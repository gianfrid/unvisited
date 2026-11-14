# PLAN — Split lib/ui/map_page.dart into ui/ modules (Technical debt 1)

TODO unit: "Technical debt": split map_page.dart (2K lines, 14 classes)
into `ui/` modules, including making `TrackDrawer` private-neighbor
(`_TrackTile` already is). Pure code motion — no behavior change; the
widget tests assert by text/tooltip/key and must pass untouched.

## Target layout

| New file | Contents (moved verbatim, private names made public where they cross files) |
|---|---|
| `lib/ui/format.dart` | `formatDistance`, `formatDuration` (was `_format*` — used by map_page, the stats panel and the track tiles) |
| `lib/ui/map_actions.dart` | `EmptyHint`, `BadgeIcon`, `FloatingToolbar`, `HeaderAction` — the shared map chrome widgets |
| `lib/ui/zoom_slider.dart` | `ZoomSlider` + its private step button, and the map zoom bounds `mapMinZoom`/`mapMaxZoom` (was `_minZoom`/`_maxZoom`, shared with `MapOptions`) |
| `lib/ui/stats_panel.dart` | `StatsPanel` — the recording dashboard's expanded panel |
| `lib/ui/settings_sheet.dart` | `SettingsSheet`, `TintSwatch`, and the `_pickLanguage`/`_pickTheme`/`_pickRoadData` dialogs |
| `lib/ui/track_list.dart` | `TrackDrawer` (public name kept) + `_TrackTile` — now only reachable through map_page, so the class is no longer an unowned public API |

`map_page.dart` keeps `MapPage`/`_MapPageState`, `nearestEquivalentRotation`
(only the camera logic uses it) and the stop-with-name dialog, importing
the new modules. The recording stack/dashboard builders stay — they are
stateful against `_MapPageState`'s follow-camera and latch flags.

## Implementation steps

1. Extract the ranges by line into the six files with proper imports
   (bottom-up deletions in map_page.dart so line numbers stay valid);
   drop the underscore prefixes on the moved public-facing classes.
2. Update map_page.dart's imports: add the six modules; drop
   `build_version` (only the settings sheet uses `AppVersion`) and any
   other import analyze reports as newly unused.
3. Update the moved identifiers' references inside map_page.dart
   (`_formatDistance` → `formatDistance`, `_SettingsSheet` →
   `SettingsSheet`, `_minZoom` → `mapMinZoom`, etc.).

## Out of scope

No behavior change, no reflow/reformat of moved code, no new widget
keys or strings; the aggregate-selection unit lands on top of these
modules later. Not touched: app_model (separate debt unit), test files.

## Verification

`flutter analyze` clean (which also proves no unused imports/refs);
`flutter test` 239/239 — the widget suite is the behavior witness.
