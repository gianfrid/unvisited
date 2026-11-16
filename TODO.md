<!-- Open work lives here; completed items are deleted, not ticked. -->

- Recording follow-camera / marker polish (user report, 2026-11-16):
  1. Smooth the course-up camera rotation — it is laggy/choppy: each 1 Hz
     fix eases the camera only `rotationSmoothingFactor` (0.4) toward the
     raw heading, so heading noise steps the camera. Add circular smoothing
     of the heading over recent fixes (and/or time-based easing) so the
     rotation glides. `RecordingDashboardState._onRecordingFix`.
  2. Direction marker must always point up — `_recordingMarkers()` in
     `map_page.dart` rotates the navigation triangle by
     `course - camera.rotation`; make it fixed screen-up (course-up mode
     already nets to 0). Update the marker-angle widget tests.
  3. Record button must require a fresh position fix — `_gpsWorking` is
     set by any `locate()` success, and Android's fused provider can return
     a stale cached fix, so Record can appear with no real position (and a
     cold-started session then shows no marker until its first accepted
     fix). Gate Record on fix freshness (e.g. position timestamp age) and
     cover with tests.
