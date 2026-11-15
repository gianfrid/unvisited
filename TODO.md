<!-- Open work lives here; completed items are deleted, not ticked. -->

## Map rotation in recording mode (from docs/map-rotation-research-report.md §5)

1. Smooth the rotation: keep the 1° hysteresis and short-arc wrap, but
   approach the target with exponential smoothing per fix instead of an
   instant snap (no new dependency).
2. Release-on-pan with timed re-engage (15–30 s, OsmAnd auto-follow model)
   instead of "next fix re-applies"; the existing locate button also
   re-arms immediately.
3. Treat user two-finger rotation as a mode switch to manually-rotated,
   suppressing auto-rotation until the re-engage timeout/button (watch
   `mapEventStream` rotate events with a non-programmatic source).
4. Rotation-mode indicator on the recording dashboard: small
   compass/north button showing the mode, cycling off → course-up, and
   doubling as the re-engage affordance from item 3.
5. GPS-loss behavior: no fix for > ~10 s → hold last rotation; never
   rotate on a stale heading.
6. Optional (+`flutter_compass` dep, ask first per AGENTS.md): true compass
   heading below the speed gate, subscribed only while recording with
   rotation on.
