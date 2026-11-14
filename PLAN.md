# Slice 15 — live recording trace drawn on the map

## Context

While recording, accepted fixes exist only in the staged GPX; the map
shows just the course-up marker. The trace of the current session should
plot live. The session currently keeps only `_lastLat/_lastLon`, so it
must start exposing the accepted points grouped by `<trkseg>` (the same
breaks the stage writer sees: pause and fix-loss gaps).

## Steps

1. `lib/recording/recording_session.dart` — the engine accumulates
   `List<List<LatLng>> _liveSegments` alongside the staged writes: the
   accepted fix appends to the last segment; `gap > segmentGap` and
   `pause()` open a new one. Exposed read-only as `liveSegments` (a
   defensive copy). No behavior change to distance/timers.
2. `lib/ui/map_page.dart` — while `model.recording != null`, render a
   `PolylineLayer` with the session's `liveSegments`, placed above the
   fog circles and road corridors and below the recording marker:
   - color: a fixed recording red (`Colors.redAccent`) at ~0.65 opacity,
     stroke width 4 — deliberately outside the catalog track-tint
     family, and translucent so it reads as in-progress;
   - segments with a single point render as a dot-sized polyline skipped
     (a polyline needs ≥2 points), same rule as corridors.
   - The layer is absent when no session runs; after stop the finalized
     track appears as an ordinary catalog track (unchanged path).
3. Tests:
   - engine (`test/recording_session_test.dart`): accepted fixes build
     segments; a pause splits them; a fix-loss gap splits them; paused
     fixes add nothing.
   - widget (`test/map_page_test.dart`): fake-sourced session, two fixes —
     a `PolylineLayer` with one two-point polyline at the recording tint
     is present while recording and gone after stop; its color is the
     fixed red, not the track tint.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 15 TODO entry; PLAN.md
  carries over to the next task unmodified.
