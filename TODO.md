<!-- Open work lives here; completed items are deleted, not ticked. -->

Post-debt-backlog residuals (from the recording-dashboard extraction review):

1. - [ ] Shrink `map_page.dart` further (now ~1090 lines after the dashboard
   extraction; the plan's aspiration was well under 900): the remaining mass
   is the bottom-left action stack (locate/record/pause/stop), the import and
   settings handlers, and the fog/corridor/selection builders — candidates
   for their own widgets/modules in `lib/ui/`, with `map_page_test.dart`
   assertions kept unchanged.
2. - [ ] Tighten `RecordingDashboard`'s rebuild granularity: its build listens
   to `Listenable.merge([model, recordingLive])`, so every 1 Hz fix repaints
   the whole dashboard (chip + speed + latch icon). Narrow it to what actually
   changes per fix (duration/distance/speed text) and rebuild the
   latch/boundary-only parts on model notifications only, again with
   `map_page_test.dart` assertions unchanged.
