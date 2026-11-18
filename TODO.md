<!-- Open work lives here; completed items are deleted, not ticked. -->

## Show unvisited roads in the current view

Final objective: with a road region active, the map surface shows which
roads around the current view are still unvisited.

2. Unvisited-roads overlay: draw the unmatched geometry of the viewport's
   ways in a distinct style, reusing the coverage pass from unit 1
   (`lib/road/road_coverage.dart`) with way geometry instead of scalars.
