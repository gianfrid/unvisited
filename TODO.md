<!-- Open work lives here; completed items are deleted, not ticked. -->

Technical debt — high priority (owner-approved 2026-11-14; findings above
the rest of the backlog by intent):

1. - [ ] Split lib/ui/app_model.dart (868 lines, 6 concerns): a recording
   controller (start/stop-with-name/pause/salvage staging) and an import
   coordinator (the three near-parallel import paths collapsed onto one
   helper for the store+roads+cache+summary choreography), keeping
   settings/locate on the model.
2. - [ ] Per-fix repaint granularity: `notifyRecordingFix` notifies the
   whole tree at 1 Hz and `liveSegments` deep-copies every segment per
   rebuild — a scaling wall for long sessions. Give the recording live
   state its own Listenable (stats/trace/marker) so the fog overlay and
   toolbar rebuild channels stay untouched.

Track list — catalog UX:

1. - [ ] Per-track menu: a ⋮ button on each track tile opening a menu with
   Info, Delete and Export. Delete keeps the existing confirmation dialog;
   swipe-to-delete stays as is.
2. - [ ] Track info from the menu: a dialog with start date/time, format,
   point count, distance, duration, average speed (distance over duration).
   All strings en + it.
3. - [ ] Export from the menu: share/save the track's original stored file
   as-is (share sheet on Android, save dialog on desktop Linux) — recorded
   tracks export as the GPX they were finalized into. Widget tests for the
   menu wiring; strings en + it.

Bugs — high priority:

1. - [ ] Test the engine's `currentHeading`/`currentCourse` split (the
   state itself landed in b6fdfe8 with getter docs claiming "unit tests
   both ways" — its diff touched no test file; the message overclaimed).
   Unit tests for the two behaviors: a fix that carries a heading sets
   both getters to it; a heading-less fix leaves `currentHeading` null
   while `currentCourse` keeps bridging the bearing between fixes.
2. - [ ] Gate the course-up camera rotation on the device-reported
   heading — the magnetometer-backed signal — so a sensor-less or
   bearing-only stream keeps the camera north-up with the marker still
   rotating; and smooth what remains (the course-delta hysteresis below
   the threshold landed in b6fdfe8, but the rotation still rides
   `currentCourse` — map_page.dart has no `currentHeading` gate, so a
   bridged-bearing stream still spins the camera). No new packages: a
   dedicated magnetometer plugin would be a package decision beyond the
   established set — the gate rides the heading the position fixes
   already report.

Map — aggregate tracks & selection:

1. - [ ] Aggregate track model: cluster the visible stored tracks so that
   points of different tracks within ~100 m belong to the same aggregate
   track. Pure Dart behind a small interface (like the parsers), unit
   tests on synthetic fixtures: chains, singletons, threshold edge cases.
2. - [ ] Tap-to-select: tapping the map within tolerance of an aggregate's
   points selects it (visual highlight); a selection bar offers hide
   (deselect = underlying tracks visible=false), change color
   (per-aggregate override persisted in index.json) and fit screen to the
   aggregate.
3. - [ ] Remove the global Fit button from the top toolbar — fitting is per
   aggregate via selection now; the startup camera fit is unchanged.
4. - [ ] Colors: extend the tint palette beyond the current four; aggregates
   render in palette colors — the main fog aggregate keeps the fixed
   default color, distant aggregates take the next palette colors,
   overridable per selection. The Settings "track color" row now drives
   only the live recording trace color (replacing the fixed red). Strings
   en + it; widget tests for selection and highlight.

Packaging:

1. - [ ] Rename the app package com.example.unvisited →
   io.github.gianfrid.unvisited everywhere it appears: Android namespace +
   applicationId (android/app/build.gradle.kts) and MainActivity package +
   source dir, Linux APPLICATION_ID + desktop file + desktop-entry.sh,
   iOS/macOS PRODUCT_BUNDLE_IDENTIFIER. Verify with flutter analyze,
   flutter test and an Android debug build.
