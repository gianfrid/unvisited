<!-- Open work lives here; completed items are deleted, not ticked. -->

1. Recording: the follow-camera snaps between fixes — `_setGlideTarget` resets the glide ticker's clock even when it reuses a running ticker, so a fix arriving mid-ease jumps ~96% of the remaining distance in one frame (unit 3 of docs/plans/2026-11-19-recording-field-bugs.md).
2. Recording: decide and document elevation semantics — recorded GPX writes raw GPS height, ~47 m above a calibrated watch's MSL in the field comparison; needs an offline geoid model or an explicit raw-altitude caveat.
