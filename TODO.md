<!-- Open work lives here; completed items are deleted, not ticked. -->

Technical debt backlog (from the codebase debt analysis — refactoring,
code smells, doc drift, test gaps):

1. - [ ] Extract the recording dashboard out of `_MapPageState`
   (`map_page.dart`, 1344 lines, the churn hotspot): follow-camera +
   course-up, HUD chip / stats panel wiring, screen latch and salvage
   toast into their own widget; update `map_page_test.dart`.
