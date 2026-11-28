<!-- Open work lives here; completed items are deleted, not ticked. -->

## Overlay recomputes can land out of order after a catalog change

`_recomputeViewportCoverage` (lib/ui/app_model.dart) captures
`mergedCorridors()` before its two awaits and its only supersede guard compares
corners — which a catalog change does not move — so a pass that started before
an import or a visibility toggle can overwrite the fresh answer afterwards with
a stale-corridors overlay/report, wrong until the next settle.

- coverage-recompute-order-1: sequence the recomputes (or supersede on a
  catalog epoch) so only the newest input's answer lands.
