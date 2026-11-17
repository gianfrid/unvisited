# Recording marker: point along the course, keep it clear of the HUD

Implements: —

## Symptoms (reproduced red in `test/marker_repro_test.dart`, throwaway loop)

1. Course mode: the marker is pinned screen-up (`angle: 0`) while the camera
   rotation eases/gates/compass-substitutes — repro: camera at -57.6°, marker
   at 0, course-on-screen should be 32.4°.
2. The marker rebuilds from the fix channel *before* the dashboard applies the
   camera move (subscription order: the marker layer mounts earlier in the
   tree), so its `camera.rotation` read lags one fix — the nose trails during
   turns even after fixing 1.
3. The follow-camera frames the fix at 68% of screen height; the bottom column
   (action stack + chip + speed card + stats panel) reaches ~66% of an 800 px
   screen with the panel open — the marker renders under the cards
   ("disappears"). Measured: marker y 524–563 vs chip top 528.

## Fixes

### A. Marker angle — one formula for both modes (`map_page.dart`)

Delete the pinned-screen-up ternary; always
`angle = ((currentCourse ?? 0) + rotation) * pi/180`, with `rotation`
read from the notifier (B) instead of `camera.rotation` at build time.
The session's `currentCourse` already falls back to the fix heading, so the
marker points along the direction of travel on screen and nets to
straight-up exactly when the camera is on-course. Semantics at a
standstill in course mode (compass-driven rotation): the marker shows
the stale GPS course against the rotating map — "where you were
heading" — consistent with north mode; no pinning. Update the doc
comment (the "pinned screen-up" rationale is obsolete).

### B. Rotation published, not read at build time

`MapPage` owns a `ValueNotifier<double>` holding the **camera rotation
only**; the dashboard updates it after every rotation change it applies
(`moveAndRotate` in `_onRecordingFix`) and from its existing map-event
listener on rotation gestures (after a follow release, manual two-finger
rotations must still reach the marker). The marker layer listens to
`Listenable.merge([recordingLive, rotationNotifier])` and computes
`course + notifier.value` — always the post-move rotation, same frame
(the dashboard's synchronous listener runs before the build phase).
Rotation-only keeps the released-follow case correct with no special
casing: `_onRecordingFix` early-returns there, but the rotation truly
does not change, and per-fix course updates still arrive through the
marker's own `recordingLive` subscription. `rearmFollow` needs no
update (`move` does not rotate).

### C. The HUD stops covering the fix

1. Merge the headline speed into the HUD chip row (dot, duration, distance,
   speed at `titleLarge` wrapped in `Flexible` with ellipsis, rotation
   button, chevron); delete the separate `RecordingSpeedReadout` card —
   the column loses ~70 px without losing information ("make it
   shorter"). Paused / pre-first-fix shows the same `—` the readout used;
   no new strings. The 360×740 regression test asserts no overflow
   (`tester.takeException()` stays null).
2. `StatsPanel` → 2-column grid (5 stats in 3 rows instead of 5).
3. Dynamic follow lead: the dashboard measures its own rendered height
   (`context.size`, guarded for null before the first build) and offsets
   the fix to sit just above the bottom column:
   `lead_px = height/2 - (ownHeight + bottomAllowance) - margin`, clamped
   to `[0, height * 0.35]`, replacing the static `followLeadFraction =
   0.18`. `bottomAllowance` covers the action stack plus the bottom
   SafeArea inset read from `MediaQuery` (gesture-nav bars differ from a
   fixed 16) and a margin; the exact constant gets tuned against the
   tests. On a 360×740 surface with the panel open the lead clamps to 0 —
   the marker sits at center, still above the column. The panel toggle
   re-applies the framing immediately while the follow is armed (not on
   the next fix).

### D. Tests

Fold the throwaway loop into `map_page_test.dart` as regression tests:

- marker points along the course on screen while the rotation eases (the
  current red assertion);
- marker clears chip/speed/panel on 411×915, 411×800 and 360×740 surfaces,
  panel open and closed;
- the existing settled-state test (rotation −90 ⇒ marker straight up) must
  stay green — the formula nets to 0 there;
- speed-in-chip and 2-col panel assertions replace the old panel/speed-card
  expectations in the dashboard test; the throwaway
  `test/marker_repro_test.dart` is deleted once folded in.

### E. Docs

`ARCHITECTURE.md` dashboard paragraph: chip carries the headline speed; the
follow lead clears the bottom column dynamically; the marker always shows the
course on screen (no more pinning).

## Out of scope

- Tilted/pitched map view (backlog, upstream flutter_map).
- Any new sensor or permission.
