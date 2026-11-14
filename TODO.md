<!-- Open work lives here; completed items are deleted, not ticked. -->

Recording dashboard UX (triage):

1. - [ ] Stop popup actions: after pressing Stop the primary button should
   read Save (not Stop), and a Discard button should be offered alongside.
   Lives in the recording popup (`lib/ui/recording_live.dart`).
2. - [ ] Stop button visible while recording, not only after Pause —
   change from the previous design; control visibility in
   `lib/ui/recording_live.dart` / `lib/ui/recording_controller.dart`.
3. - [ ] Record button hidden until a position fix is obtained (gate the
   button in `lib/ui/map_page.dart` on the first fix).
4. - [ ] Bottom buttons need a background — a bar like the top one or the
   zoom slider (`lib/ui/zoom_slider.dart`) — they are not readable on the
   map. Styling of the bottom action bar in `lib/ui/map_page.dart`.
5. - [ ] Aggregate track menu is too large; integrate its buttons into the
   top bar instead (`lib/ui/map_page.dart` / `lib/ui/map_actions.dart`).
