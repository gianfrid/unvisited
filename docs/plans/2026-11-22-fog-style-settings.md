# Fog-of-war display style: circles / uniform polyline / simulated ink, selectable in Settings

Implements: — (direct user request)

Request: the fog-of-war overlay should also be displayable as a **uniform
polyline** (the rendering the fog overlay replaced in c49bd93 —
`_buildMergedPolyline`: one polyline per track segment, uniform width, thin
border), plus an **ink-like appearance that simulates ink strokes** (a
hand-drawn pen line, not a flat vector stroke); all selectable in Settings.
Eyecandy must not cost performance: the line styles ride the same cost
curves as the circles (see Performance).

## Design

One new persisted setting, `settings.fogStyle` in `index.json`, with three
values:

| Value | Rendering |
|---|---|
| `'circles'` (default) | Current behavior: translucent unlock `CircleMarker`s, one per occupied grid cell, coarsening with zoom. Unchanged. |
| `'polyline'` | The old look: per visible track, its points as polyline segment(s) (split where consecutive points are far apart, so `<trkseg>` breaks and teleports don't draw artificial connections), uniform stroke width ~3.5 px + thin border, colored by the track's aggregate tint at a raised alpha. |
| `'ink'` | Same segment geometry, but **simulated ink strokes**: each segment draws as layered passes (a wide low-alpha "bleed", a mid pass, a narrow near-opaque "core"), each pass jittered by a small deterministic perpendicular offset and cut into short runs of slowly varying width — ragged edges, ink pooling, pen-pressure wobble. Deep blue-black ink hue. |

Ink simulation properties (pure Dart, no new packages):

- **Deterministic**: every jitter/width value derives from an FNV-1a hash of
  the quantized point coordinates + a per-pass seed (the project already
  uses FNV-1a for content hashes), so rebuilds never flicker.
- **Bounded**: perpendicular jitter ≤ ~1.5 m (sub-pixel at low zoom);
  analogous width bands per pass.

Unknown or missing `fogStyle` values fall back to `'circles'` (same
discipline as the other settings). The style is presentation-only: unlock
math, road matching, persistence and the playback "hide the fog" rule are
untouched — while a replay runs, whichever fog layer is active stays hidden.

Settings sheet: a new **"Fog style"** segmented row (Circles / Polyline /
Ink) directly under the tint swatches, mirroring the "Map type" row.

## Performance (the eyecandy gate)

The circles' whole cost story is the power-of-two cell grid: a whole-hobby
catalog collapses to a few hundred blobs at world zoom. The line styles
must ride the same curve or they are not shippable. Concretely:

1. **Band-driven decimation for all line styles.** The page already tracks
   `_fogCellSize` (doubled per zoom band, from `fogCellSizeFor`); polyline
   and ink decimate input points by `k = cell / baseCellSizeMeters` (every
   k-th point) — the same "geometry only ever smooths to within one cell,
   invisible at that zoom" contract the circles have. At street zoom
   (k = 1) the polyline style is pixel-identical to the old look.
2. **Ink passes shed with the band.** 3 passes (core + mid + bleed) only
   at the two finest bands; core + mid beyond; core-only from the third
   doubling on, where all but the core line are sub-pixel anyway. A trace's
   paint cost converges on that of the plain polyline style exactly where
   the view is wide enough to hold many tracks.
3. **Run-length budget degradation.** Runs are the width-wobble units; the
   polyline count per pass is `points / runLength`. Strips start at ~16
   points and **double in length whenever a pass would exceed the per-track
   polyline budget** (`_maxInkPolylinesPerTrack`, ~1000 — the knob), so
   geometry is never dropped, only simplified in width detail. Guaranteed
   floor: one run per pass → a track never costs more than its pass count
   in polylines, i.e. at worst exactly the plain polyline style. In no
   configuration can ink cost more than a constant factor of the old
   rendering the app once shipped by default.
4. **Compute-once caches, keyed like the circles'.** Ink strips and
   polyline point lists are computed per track @ band and cached in the
   page (`_inkStrokesByTrack`, mirroring `_fogCentersByAnchor`: accumulates
   per key, bounded by tracks × few bands). Pan/zoom inside a band and all
   model rebuilds reuse the cache; recomputes happen only on band crossings
   and catalog/import changes — the existing pattern. The jitter math
   itself is O(points) arithmetic, negligible next to building the widget
   list once per band.
5. **No new paint machinery.** flutter_map already culls off-screen
   polylines and simplifies per zoom (the corridor layer relies on the
   same); no timers, no per-frame work, no async — styling degrades, it
   never blocks. The corridor/unvisited layers are untouched by fogStyle.
6. **Numbers, not vibes, in tests.** No timing assertions (repo rule):
   a synthetic 50k-point track unit test asserts the decayed outputs —
   decimation factor, pass count per band, and total polyline count ≤
   budget — pinning the cost contract exactly the way
   `road_store.parsedBucketCount` pins lazy loading.

Manual verification adds: with a real catalog, switch between the three
styles and pan/zoom at both street and city zoom on desktop profile mode;
no visible jank difference versus circles.

## Steps

1. `lib/storage/track_store.dart` — add `fogStyle` to `AppSettings`
   (field, default `'circles'`, `fromJson` fallback, `copyWith`, `toJson`)
   plus `saveFogStyle(String)`, mirroring `tileLayer`.
2. `lib/ui/fog_of_war.dart` — style keys (`fogStyles`, `defaultFogStyle`,
   `fogStyleOrDefault`), a pure `splitTrackSegments(points,
   {maxGapMeters})` helper (restores the old "no artificial connections"
   split), and a pure `decimate(points, k)` helper (every k-th point).
   Stays Flutter-free.
3. `lib/ui/ink_stroke.dart` (new, pure Dart + latlong2 only, like
   `fog_of_war.dart`) — the ink generator: given one segment's (decimated)
   points and a band config, returns `List<InkPass>` where
   `InkPass = ({Color color, List<({List<LatLng> run, double width})> strips})`.
   Jitter via FNV-1a-seeded perpendicular offsets; width modulated by slow
   noise over arc length with the run-length budget rule (Performance §3);
   pass set per band (Performance §2); jitter/width bounds as constants.
4. `lib/ui/track_colors.dart` — the ink hue constant (deep blue-black) with
   the core/mid/bleed alphas, next to the exploration tints; a helper for
   the polyline style's raised-alpha tint.
5. `lib/ui/app_model.dart` — `fogStyle` getter (normalized through
   `fogStyleOrDefault`) + `setFogStyle(...)` → `store.saveFogStyle` +
   `notifyListeners()`.
6. `lib/ui/map_page.dart` — where the fog layer mounts
   (`if (widget.model.playback == null) CircleLayer(...)`), branch on the
   style: circles → existing path; polyline → `PolylineLayer`, one
   `Polyline` per segment per track in the aggregate tint, thin border;
   ink → `PolylineLayer` from the cached `ink_stroke.dart` passes. Both
   line styles read the per-track @ band cache (Performance §4) and
   decimate by the tracked band (Performance §1). The replay-hides-fog
   gate wraps whichever layer mounts; the selection highlight stays
   circles.
7. `lib/ui/settings_sheet.dart` — "Fog style" `SegmentedButton<String>` row
   after the tint swatches, wired to `model.fogStyle` / `setFogStyle`.
8. `lib/l10n/app_strings.dart` — five new strings in the abstract class +
   English + Italian: `fogStyle`, `fogStyleSubtitle`, `fogStyleCircles`,
   `fogStylePolyline`, `fogStyleInk`.
9. Tests:
   - `test/app_strings_test.dart` — the five keys in `allStrings` (pins
     both languages).
   - `test/fog_of_war_test.dart` — `splitTrackSegments` gap-splitting,
     `decimate`, `fogStyleOrDefault` fallback.
   - `test/ink_stroke_test.dart` (new) — determinism (same input → identical
     output), jitter and width bounds, pass set per band, run-length budget
     (10k/50k synthetic tracks: total polylines ≤ budget, floor = pass
     count), degenerate segments (0/1/2 points).
   - `test/app_model_test.dart` — persistence round-trip + unknown-value
     fallback, mirroring the `tileLayer` test.
   - `test/map_page_test.dart` — `fogStyle: 'polyline'` renders a
     `PolylineLayer` with the track's points and no fog `CircleLayer`;
     `'ink'` renders multiple passes; the settings row switches
     `model.fogStyle`.
10. Docs — SPEC.md scope item 5 gains a sentence (the overlay's display
    style is selectable in Settings; circles default; line styles ride the
    circles' cost curve), plus the rendering / appearance-settings
    paragraphs in ARCHITECTURE.md.
11. Verify: `flutter analyze` clean, `flutter test` passes; the manual
    style-switch/pan check of Performance §6; commit plan + change in one
    commit.
