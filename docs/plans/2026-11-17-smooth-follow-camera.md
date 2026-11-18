# Smooth follow-camera: glide between fixes instead of 1 Hz snaps

Implements: —

## Symptom

While recording with the follow armed, `RecordingDashboard._onRecordingFix`
jumps the camera once per fix (1 Hz): `move`/`moveAndRotate` are instant, so
the view stutters — position snaps, rotation eases in discrete 40%-per-fix
steps.

## Approach — hand-rolled glide ticker (no new package)

`flutter_map` 8.3.2 has no animated `move` (verified in the package source),
and `flutter_map_animations` would be a new dependency plus a controller
wrapper. Instead, `RecordingDashboardState` (gaining
`TickerProviderStateMixin`) runs a **glide ticker**: a critical-damped
per-frame exponential approach of the whole camera (center + zoom + rotation)
toward a per-fix target — the OsmAnd-style "always converging" model, prior
art §3/§5 of `navigation-follow-camera-prior-art-research-report.md`.

1. **Per fix** (`_onRecordingFix`): compute the *target* exactly as today —
   dynamic-lead framed center, zoom floor, circular-mean rotation through
   `nearestEquivalentRotation`, existing gates (1° `courseDeltaThreshold`,
   compass speed hysteresis, gps-loss hold) — and store it; no direct camera
   call. The manual `rotationSmoothingFactor` (0.4/fix) is *subsumed* and
   removed.
2. **Ticker callback**: with each frame's `dt`,
   `x += (target - x) * (1 - e^(-dt/τ))`, τ ≈ 350 ms
   (`followGlideTimeConstant`), rotation through the short arc; one
   `moveAndRotate` per frame; marker rotation published per frame
   (`markerRotation` notifier — the marker layer is the scoped rebuild).
   Stop the ticker when settled (center/zoom/rotation deltas below epsilon) —
   no continuous repaint at a standstill; mid-ride the map repaints while
   gliding, like every moving-map nav app.
3. **Cancellation**: follow released by a gesture, session end, dispose, or
   pause → target cleared, ticker stopped (the user's hand owns the camera).
   `rearmFollow` re-arms the target on the next fix (current behavior).
4. Marker angle during the glide stays on-screen-correct automatically: it
   reads the per-frame-published rotation (the invariant "course + rotation"
   holds at every frame).

## Tests

- New helper `pumpGlide(tester)`: pumps ~100 ms steps until the ticker is
  idle (bounded, deterministic). Recording camera tests that assert after
  2 plain pumps (`follows`, `rotates course-up`, pan-release, compass gate +
  hysteresis, stale-GPS hold, dynamic lead, marker-clears-bottom-column)
  pump it after their fix sequences; expectations that assumed per-fix
  40% easing (e.g. rotation `-57.6` after two fixes) change to the settled
  values (`-90` for a steady 90° course).
- The mid-ease marker test becomes an invariant assertion — at a pinned
  mid-glide pump, `markerAngle == (course + camera.rotation)` normalized —
  robust regardless of the easing state instead of pinned numbers.
- New test: from a released follow with mid-flight rotation, the camera
  converges with a continuous short-arc rotation (sampling several frames:
  monotone approach, no overshoot/snap).

## Docs

`ARCHITECTURE.md` dashboard paragraph: per-fix camera application becomes
the glide ticker (exponential approach, τ ≈ 350 ms, settles when close;
rotation's per-fix easing factor folded in).

## Out of scope

- `flutter_map_animations` / animated zoom elsewhere (Locate, fits stay
  instant — deliberate, they are user-initiated jumps).
- Compass-driven rotation faster than the 1 Hz fixes (the camera updates
  per fix as today; the glide only smooths the application).
