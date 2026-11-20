# Playback on a phone: the bar fits the narrow surface; a zoom hand
# (slider, wheel) no longer fights the follow-camera

## Diagnosis (already reproduced red at the harness — test/probe_loop_test.dart)

Two independent defects, each with a deterministic failing probe at
the 360×740 narrow surface:

1. **The playback bar does not fit a phone screen.** At 360 logical
   px the bar's single `Row` throws `RenderFlex overflowed by 13
   pixels on the right`; the `Expanded` scrubber and the `Flexible`
   track name both render **0 px wide** (invisible, ungrabbable).
   Predates the instant-speed slice (the `9ebaf32` baseline shows the
   identical overflow); the recording toolbar has a
   "fits the narrowest surface" test, the playback bar never did.
2. **A user's zoom fights the armed follow-camera below the
   followZoomFloor (17).** While a replay (or recording) rides the
   shared FollowCamera, each tick's `update()` targets
   `max(camera.zoom, 17)`, so any zoom-out below 17 is walked back by
   the glide within a tick or two:
   - the **lateral zoom slider** does `controller.move(center, zoom)` —
     a programmatic event the follow ignores by design ("programmatic
     moves leave the follow armed"): probe 16.8 → 7.9 after the drag,
     13.1 and climbing back a few ticks later;
   - the **desktop scroll wheel** (flutter_map 8.3.2 already enables
     it inside `InteractiveFlag.all` — verified green without a
     follow) is likewise not a follow-releasing gesture: probe 16.8 →
     12.0 after the scroll, walking back identically.

## Design

### Fix 1 — the bar fits 360 logical px

`lib/ui/playback_dashboard.dart`, `_bar`: the single `Row` becomes a
two-line `Column` inside the same one compact `Card`:

- line 1: play/pause · `Expanded` scrubber (real width at 360) · close
- line 2: track name (`Flexible`, elided) · elapsed/total · instant
  speed (in the existing time/speed stack — the layout's existing
  hierarchy from the 2026-11-20-playback-bar-title-timer-styles plan
  is kept) · speed chip · rotation button

The one compact Card stays (the follow-camera already measures the
bar through `bottomOverlap`; a slightly taller bar just shifts the
framing lead — same mechanism the panel-open recording already
exercises).

### Fix 2 — the follow-camera adopts the zoom hand, releases on the wheel

Both fixes in the shared `lib/ui/follow_camera.dart`, so recording and
playback gain them together; the slider is a **zoom intent** (the ride
keeps following at the user's zoom), the wheel is a **camera-moving
hand** (it releases, like a pinch):

- **Slider adoption:** the existing event listener grows a branch — a
  `mapController`-source move with `oldCamera.center == camera.center`
  and a changed zoom is the lateral slider's signature (it passes
  `camera.center` through unchanged; the follow's own glide frames move
  the center every tick a ride is advancing). On that signature the
  camera stores `_rideZoom = zoom`, and `update()` targets
  `_rideZoom ?? max(camera.zoom, followZoomFloor)`. The floor stays
  the default for any ride that never saw a zoom hand. `reset()`
  (session/replay boundary) clears `_rideZoom` — a fresh ride starts
  under the floor policy.
  Mis-attribution (a glide ease frame that is momentarily center-static
  while its zoom converges) adopts a zoom ≈ the glide's own target —
  harmless by construction; the marker never stands still while a ride
  advances at the observed cadences.
- **Wheel release:** `MapEventSource.scrollWheel` joins `_moveGestures`
  — a wheel zoom releases the follow exactly like a pinch does, and
  the existing re-arm paths (play button, locate shortcut) are the way
  back. No feature code for the wheel itself (already on via
  `InteractiveFlag.all`, verified).

## Tests

- Minimize the probes into committed widget tests:
  - `playback_widget_test.dart`: the bar at 360×740 — no exception,
    scrubber ≥ ~100 px wide, name visible; the scrub/pause/readout
    tests keep passing at the narrow surface.
  - `map_page_test.dart` (or the fly's closest home): the lateral
    slider zoom-out *during a replay* lands below 17 **and stays**
    (currently walks back); the wheel zoom during a replay releases
    the follow and keeps the zoom; the wheel with no ride (control)
    stays as shipped.
- Engine and unit layers untouched (both fixes are camera/UI side).

## Verification

- `flutter analyze` clean, `flutter test` green, probe red loops all
  green after the fix; desktop `flutter run -d linux` manual pass:
  narrow window, scrubber visible; slider and wheel both zoom during
  a replay without snapping.
