<!-- Open work lives here; completed items are deleted, not ticked. -->

Track list — catalog UX (decomposed units; 4 and 5 added by owner):

1. - [ ] Per-track menu: a ⋮ button on each track tile opening a menu with
   Info, Delete and Export. Delete keeps the existing confirmation dialog;
   swipe-to-delete stays as is. Widget tests for the menu wiring.
2. - [ ] Track info from the menu: a dialog with start date/time, format,
   point count, distance, duration, average speed (distance over duration).
   All strings en + it.
1. - [ ] Export from the menu: share/save the track's original stored file
   as-is (share sheet on Android, save dialog on desktop Linux) — recorded
   tracks export as the GPX they were finalized into. Widget tests for the
   menu wiring; strings en + it. (Android share rides the existing host
   channel with a new shareTrack method backed by a FileProvider — no new
   packages; desktop uses file_picker's save dialog + a file copy.)
2. - [ ] Track tiles reflect the aggregate color: each tile carries a dot
   (or leading swatch) in its aggregate's resolved tint (palette rank or
   per-aggregate override — same resolution the map draws).
3. - [ ] Tapping a track tile fits its aggregate on the map (select it and
   fit the camera to the aggregate's points; the checkbox stays the
   visibility toggle).

Packaging:

1. - [ ] Rename the app package com.example.unvisited →
   io.github.gianfrid.unvisited everywhere it appears: Android namespace +
   applicationId (android/app/build.gradle.kts) and MainActivity package +
   source dir, Linux APPLICATION_ID + desktop file + desktop-entry.sh,
   iOS/macOS PRODUCT_BUNDLE_IDENTIFIER. Verify with flutter analyze,
   flutter test and an Android debug build.
