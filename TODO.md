<!-- Open work lives here; completed items are deleted, not ticked. -->

## Rendering slowdown with many tracks: skip already-overlapping points

- `overlap-1` — Research how to solve the many-tracks rendering slowdown: survey point-decimation / screen-space dedup / spatial-index culling approaches, and pick one that fits the fog-of-war painter (findings recorded in the plan file).
- `overlap-2` — Do not render points that already overlap with others on screen; overlapping track geometry is omitted from normal rendering, restoring smooth performance with many tracks.
- `overlap-3` — Multitrack selection mode: overlapping tracks stay hidden unless the user clicks a point that multiple tracks pass through, in which case exactly those tracks are shown/selected there.
