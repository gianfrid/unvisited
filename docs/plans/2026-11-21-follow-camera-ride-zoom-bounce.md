# Follow-camera: ride-zoom bouncing while recording

Implements: —

## Symptom

While recording with the follow armed, tapping the pill's zoom buttons makes
the zoom bounce: the camera climbs back against the tap for up to a second,
then springs the other way.

## Root cause (probed, not assumed)

The first hypothesis — the ride adopting a mid-glide zoom from the glide's
own center-static frames — does not reproduce. Probes driving the real
`MapPage` + recording session at 1 Hz and 5 Hz, stationary, jittering and
moving, from zoom 13 and from 18.5, all converge monotonically; the ride
zoom is never adopted from a glide frame in those runs.

What does reproduce is the fight with an in-flight glide. Two facts combine:

1. `FollowCamera`'s map-event listener correctly adopts a center-static
   zoom-only programmatic move (the pill's zoom button) into `_rideZoom`.
2. But the glide ticker keeps easing toward its stored target until the
   next fix re-targets it. Probe trail (zoom-out tapped 1 s into the
   opening 13 -> 17 ride):

   16.694 -> tap -> 15.694 -> 16.019 16.263 16.446 16.584 16.687 (climbing
   back) -> next fix -> 16.440 ... 15.695 (springing down)

   ~1.3 zoom levels of visible bounce per tap, twice the amplitude of the
   tap itself.

## Fix

`lib/ui/follow_camera.dart`:

1. On adopting the hand's zoom-only move, re-target the glide in flight
   onto the adopted zoom (keeping its center and rotation targets). The
   glide then stops changing the zoom in the same frame — the hand wins
   immediately instead of on the next fix — and the ride holds that zoom
   from then on because `_rideZoom` is set.
2. Tighten the adoption guard with `_lastGlideCamera`: the glide records
   the **post-move** camera it wrote (the controller clamps zoom, so it is
   read back from the camera, never the requested value), and the listener
   skips adoption for an event whose camera matches it exactly. This keeps
   the settled/barely-converged glide frames from masquerading as the
   hand's zoom. The record survives `stopGlide` (a glide frame's event can
   be delivered after the stop) and is cleared in `reset`, where no
   earlier glide frame can still be in flight.

Out of scope by decision (reported but not changed): the opening 13 -> 17
zoom-in at every recording start, and the ride floor re-asserting after a
pinch-zoom-out followed by a Locate re-arm.

## Test

`test/map_page_test.dart`: "a zoom button tapped mid-glide holds; the glide
does not ease it back" — tap zoom-out one second into the opening ride,
then assert no subsequent glide frame moves the zoom (it stays within 1e-9
of the tapped value), and that the next fix holds it too. Verified to fail
without the fix (zoom climbs to 15.868 from the 15.694 tapped value).

## Verification

- `flutter analyze` clean
- `flutter test` passes (443 tests)
