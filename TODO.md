<!-- Open work lives here; completed items are deleted, not ticked. -->

- Recording follow-camera / marker polish (user report, 2026-11-16):
  3. Record button must require a fresh position fix — `_gpsWorking` is
     set by any `locate()` success, and Android's fused provider can return
     a stale cached fix, so Record can appear with no real position (and a
     cold-started session then shows no marker until its first accepted
     fix). Gate Record on fix freshness (e.g. position timestamp age) and
     cover with tests.
