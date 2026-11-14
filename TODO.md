<!-- Open work lives here; completed items are deleted, not ticked. -->

Track list — catalog UX:

1. - [ ] Track tiles reflect the aggregate color: each tile carries a dot
   (or leading swatch) in its aggregate's resolved tint (palette rank or
   per-aggregate override — same resolution the map draws).
2. - [ ] Tapping a track tile fits its aggregate on the map (select it and
   fit the camera to the aggregate's points; the checkbox stays the
   visibility toggle).

Packaging:

1. - [ ] Rename the app package com.example.unvisited →
   io.github.gianfrid.unvisited everywhere it appears: Android namespace +
   applicationId (android/app/build.gradle.kts) and MainActivity package +
   source dir, Linux APPLICATION_ID + desktop file + desktop-entry.sh,
   iOS/macOS PRODUCT_BUNDLE_IDENTIFIER. Verify with flutter analyze,
   flutter test and an Android debug build.
