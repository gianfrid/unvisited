<!-- Open work lives here; completed items are deleted, not ticked. -->

Optional geotagged photos (Android-only, user request 2026-11-24): a camera button opens the system camera app, and the taken photo is saved tagged with the current position; photos show as map markers, tapping one previews it and allows editing the position; Settings offers a switch that hides the whole feature but keeps stored photos. Decided with the user: `image_picker`, app-private `photos/` storage (gallery storage declined), position = latest fix in hand (session fix while recording, else the latest located fix), camera button in the record cluster. Plan: docs/plans/2026-11-24-geotagged-photos.md

6. Settings + docs — Android-only "Photos" switch (default on, persisted `settings.photos`) hiding the camera button and markers but not the stored files; SPEC (scope item + manual verification), ARCHITECTURE and README updates; tests.
