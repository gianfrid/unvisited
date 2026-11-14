# Slice 6 — Record button only when a position is actually obtained

## Context

Today the Record button shows whenever `locationSupported` is true, before
any fix exists — GPS-off leaves a dead button. The gate must be a real
position (poll once at startup / listen), not permission state. Wrinkle
found in the code: `_locatedPosition` is dropped when the user pans away
from the fix, so it cannot be the gate; the button needs its own state.

## Steps

1. `lib/ui/map_page.dart` — new `_gpsWorking` state on the state class:
   - set true whenever the silent poll returns a position and whenever the
     explicit Locate succeeds (both call `setState`);
   - never cleared by panning (only `_locatedPosition` is).
2. `lib/ui/map_page.dart` — silent retry loop: a `Timer.periodic`
   (`_fixRetryTimer`, 30 s) started when `locationSupported`, calling
   `_silentPositionUpdate()` only while `_gpsWorking` is still false;
   canceled in `dispose()` and once a fix arrives. No polling on desktop
   (`locationSupported == false`) — no host plugin, so no fixes ever.
3. `lib/ui/map_page.dart` — gate the header action: the Record/slot shows
   only when `widget.locationSupported && (_gpsWorking ||
   widget.model.isRecording)`; while recording the Stop stays regardless
   (a session implicitly began from a gated button).
4. Tests (`test/map_page_test.dart`, via the existing `mockGeolocator`
   helper), `pumpMap`-style setup with `locationSupported: true`:
   - GPS off (`serviceEnabled: false`): no Record button; after the mock
     turns GPS on with a position and the test pumps past one 30 s retry,
     the Record button appears (the startup poll's fix also shows it
     immediately, without waiting);
   - locate succeeding sets the gate too, so Record appears without
     waiting for a retry;
   - a Record button that appeared keeps its slice 5 behavior untouched.
   - desktop (`locationSupported: false`): no Record button, covered by
     assertions alongside the existing locate-is-not-offered test.

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and the slice 6 TODO entry's deletion; PLAN.md
  truncated to an empty header after the commit lands.
