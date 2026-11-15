# TODO unit 1: recording marker stays visible

Give the course-up position marker a solid backdrop disc (surface color
with a subtle outline) so it reads over the red live trace and busy map
detail, and keep it the topmost map layer while recording.

## Change
`lib/ui/map_page.dart` `_recordingMarkers()`: wrap the navigation Icon
in a Container with a circular BoxDecoration (surface color, thin
outline). Marker stays last in the layer stack.

## Tests
Widget test: while recording, the marker's backdrop is present
(find.byKey on the disc) and the marker is above the trace layer.

## Verification
analyze clean, tests pass; commit PLAN.md + change + TODO removal.
