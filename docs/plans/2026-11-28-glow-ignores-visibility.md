# Hidden tracks keep their roads out of the glow

Implements: —

## Problem (user report)

"Even with tracks hidden, the visited roads should not glow."

Hiding a track currently un-walks its roads in the unvisited picture:
`mergedCorridors()` (`lib/ui/app_model.dart`) skips hidden tracks, so the
glow re-lights the roads the hidden track visited and the chip counts them
unvisited again. That was a documented choice (ARCHITECTURE.md § Road
matching; test `hiding a track returns its roads to the overlay and the
chip`) — reversed by this change per the owner's call.

The new semantics: **hiding is presentation, not history.** A hidden track
stops drawing (circles, corridors, trace) but the roads it unlocked stay
unlocked; only deleting a track un-walks its roads (matching and persistence
are already unconditional — this makes the coverage input match them).

## Consequences (accepted with this change)

- A road visited only by hidden tracks shows neither corridor nor glow:
  a plain map road. The chip counts it walked, so the number and the glow
  stay in agreement (both answer accumulated unlock state).
- The visibility toggle still recomputes the settled viewport (the corridor
  layer redraws); the coverage answer is simply unchanged now.

## Steps

1. `lib/ui/app_model.dart` — `mergedCorridors()`: drop the
   `if (!t.visible) continue;` skip; rewrite the doc comment (all stored
   tracks' corridors merged by way id; visibility is map drawing only).
2. `test/app_model_test.dart` — rewrite
   `hiding a track returns its roads to the overlay and the chip` into
   `hiding a track keeps its roads out of the glow`: after
   `setAllVisible(false)` the overlay still excludes the walked way and the
   chip's matched meters do not drop.
3. `ARCHITECTURE.md` (§ Road matching, the `mergedCorridors` sentence):
   merged corridors feed both passes from ALL stored tracks — hiding a
   track declutters the map but does not return its roads to the unvisited
   picture; deleting it does.
4. `flutter analyze` clean, `flutter test` passes; commit.

## Out of scope

- The corridor/circle/trace layers' visibility behavior (they already draw
  visible tracks only, unchanged).
- Matching, persistence, dedup, the toggle's persistence.
