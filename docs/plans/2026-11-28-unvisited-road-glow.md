# Unvisited-roads glow

Implements: —

## Goal (confirmed against the rendered mockup)

When the "Show unvisited roads" setting is on (default on, active region
required), the unvisited roads render as a soft glow instead of flat dashed
ink. Confirmed variant, from `/tmp/unvisited-glow-mockup/mockup.png`: the
"Stronger variant" halos **with the dashed line removed** — the glow stack alone
is the road's rendering.

## Approach

flutter_map 8.3.2's `Polyline` has no shadow or blur support, and a blurred
(`ImageFiltered`) full-map layer would re-render a map-sized blur on every pan
frame. The glow is therefore synthesized from strokes: two stacked solid
strokes per stretch, both in the same neutral blue-grey (`#607D8B`):

- outer wash: width 11, alpha 0.09
- inner core: width 6.5, alpha 0.18

No dash pattern on top (removed by decision — the halo is the line now). No new
setting (the existing toggle already gates the layer), no new package, no
animation. The two strokes paint in two passes — all washes first, then all
cores — so a crossing road's wash never covers another road's core: every core
sits above every wash, uniform at junctions.

## Cost

The overlay only renders when the viewport spans at most 3×3 z12 tiles
(`unvisitedIn`'s floor), so the added strokes are bounded by the same ceiling.
Solid strokes are the cheapest stroke flutter_map paints (no dash segmentation,
round caps/joins). The layer's polyline count doubles (was one dashed per
stretch), which the floor-bounded stretch count keeps acceptable.

## Steps

1. `lib/ui/map_page.dart` — `_buildUnvisitedPolylines()`: two passes over the
   same stretches (wash, then core), no dash pattern; rewrite the method's doc
   comment (the "Dashes keep them distinct" rationale is retired — hue plus the
   halo now separates them from the solid corridors).
2. `lib/l10n/app_strings.dart` — the setting's subtitle drops its "Dashed:"
   prefix in both languages ("The roads this view still has left" /
   "Le strade che restano da esplorare qui").
3. Comments that call the overlay "dashed" become "glow": `road_coverage.dart`
   (overlayMaxTiles doc, unvisitedIn doc), `track_store.dart` (Settings doc,
   getter, saver), `app_model.dart` (getter doc, setShowUnvisitedRoads body),
   `settings_sheet.dart` (the switch's comment).
4. `ARCHITECTURE.md` — the sentence describing "dashed blue-grey strokes above
   the tiles and below the fog circles" describes the glow instead.
5. Checks: `flutter analyze` clean, `flutter test` passes. Manual desktop run:
   with a region file active, the unvisited roads read as a soft blue-grey
   glow with no hard edges and no dashes; corridors and circles still cover
   them; the setting toggle still hides/shows everything together.

## Out of scope

- A glow-intensity setting.
- Animated/pulsing glow.
- Any change to the coverage chip, matching, or persistence.
