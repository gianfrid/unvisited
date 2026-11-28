# Cassette-deck button style (selectable in Settings)

Implements: — (requested directly; interactive mockup reviewed at `docs/mockups/cassette-buttons.html`)

## What

A second visual style for the app's buttons, chosen in Settings: **Standard**
(today's look, the default) or **Cassette** — buttons drawn as mechanical
cassette-deck transport keys. A key is visibly *depressed and latched* while
its function is engaged:

- Record cluster (map edge): REC latched + **red LED blinking** while
  recording; LED steady and PAUSE latched (cap reads RESUME) while paused.
- Playback bar: PLAY latched while the replay runs.
- Control pill + toolbar `HeaderAction`s get the same keycap look (raised),
  but only the session-bearing keys latch.

Behavior, hit targets, tooltips, captions and keys are unchanged — this is
pure presentation over the existing `HeaderAction` / state machine.

## Steps

1. **Setting + persistence** — `buttonStyle` ('standard' | 'cassette') in
   `TrackStore` (`lib/storage/track_store.dart`), modeled exactly on
   `fogStyle`: constructor field, map (de)serialization, `saveButtonStyle`,
   default `'standard'`. Expose `AppModel.buttonStyle` / `setButtonStyle`
   next to `fogStyle` (`lib/ui/app_model.dart`).
2. **Settings row** — new `SegmentedButton<String>` in
   `lib/ui/settings_sheet.dart` (Button style / How the map buttons look /
   Standard / Cassette), placed after "Trace style". New getters in
   `lib/l10n/app_strings.dart` in **both** English and Italian
   (`buttonStyle`, `buttonStyleSubtitle`, `buttonStyleStandard`,
   `buttonStyleCassette`) — the untranslated-string test enforces coverage.
3. **`CassetteKey` widget** — new `lib/ui/cassette_key.dart`: a drop-in
   `HeaderAction`-shaped button (same `width`/`height`/`onTap`/label/tooltip
   contract) whose cap is a beveled `Container` (gradient face + bottom
   "throw" shadow); when `latched: true` the cap sinks (AnimatedContainer:
   translate 3px, inset shadow, darker face). A `blink` LED dot overlays the
   cap via a self-contained `AnimationController` repeating LED (disposed in
   `dispose()`). No new packages — pure `BoxDecoration`/animation.
4. **Record cluster** (`lib/ui/map_controls.dart`) — when the model's style
   is cassette, render REC/PAUSE-RESUME/STOP/Camera as `CassetteKey`s inside
   a deck-face container (same pill footprint/position so layout is
   untouched): REC latched + LED blink while recording; LED steady while
   paused; pause key latched while paused. Standard style keeps today's code
   path.
5. **Playback bar** (`lib/ui/playback_dashboard.dart`) — cassette style
   swaps the two `IconButton`s (play/pause, close) for deck keys (PLAY
   latched while playing; PAUSE latched while paused; EJECT = close).
   The scrubber and timer stay as they are.
6. **Control pill & toolbar** — `MapControlPill` and `FloatingToolbar`
   actions render as raised keycaps (no latching — they are momentary keys),
   sharing the `CassetteKey` visuals.
7. **Tests** — widget tests: cassette style renders; REC latched + (pumping)
   LED animating while `isRecording`; pause latching while paused; settings
   segment switches the style; standard style unchanged; string coverage
   (EN + IT) passes via the existing test.
8. `flutter analyze` clean, `flutter test` green; commit (mockup rides
   along — it is part of this plan's record).

## Constraints honored

- No new packages (Material only); no behavior change; keys on the widget
  tests (`record-cluster`, `control-pill`, `playback-play`, …) preserved.
- Localized strings for every new user-visible label; icons stay Material
  glyphs — the deck symbols are drawn glyphs, not strings.
