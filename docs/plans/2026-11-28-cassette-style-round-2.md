# Cassette style, round two: floating keys, one REC key, retro scrubber

Implements: — (feedback on 265ee20, reviewed against docs/mockups/cassette-buttons.html)

## What

Three refinements to the cassette button style, from user feedback after the
first slice:

1. **One REC/PAUSE key** — back to a single record slot (like the flat
   style), now with the deck's visual clues: raised red REC while idle,
   latched down with the LED **blinking** while recording (reading
   Pause), latched with the LED **steady** while paused (reading
   Resume). The separate always-latched REC key and its dead-button
   "pressing REC does nothing" go away.
2. **No bar behind the buttons** — the deck face ([CassetteDeck]) is
   dropped: the keycaps float directly over the map, carrying their own
   throw shadows. Scope per the user's answer below (edge clusters only,
   or edge clusters + top toolbar).
3. **Retro seek bar** — the playback scrubber restyled as a cassette
   transport control: a recessed dark groove and a vertical capstan-style
   thumb (custom `SliderTheme` shapes: track groove + rectangular
   thumb), replacing the default Material slider. Scope per the user's
   answer below (cassette style only, or always).

## Steps

1. **Merge the record slot** (`lib/ui/map_controls.dart`): cassette mode
   renders the same single toggle slot the flat style renders, with the
   cassette props on it — `latched: recording`, `led:` blink while
   recording / steady while paused / off idle, `rec: true` only while
   idle (the red REC glyph; the pause/play glyphs stay normal while a
   session runs). The `if (cassette && recording)` two-key spread is
   deleted.
2. **Drop the deck face**: delete `CassetteDeck` from
   `cassette_key.dart`; `MapControlPill` and `RecordCluster` return their
   key columns/rows bare in cassette mode (no container — the keys'
   own `BoxShadow`s carry the depth). The top toolbar joins them if the
   user picks that scope (`TopToolbar` returns a bare `Row` instead of
   `FloatingToolbar`).
3. **Retro scrubber** (`cassette_key.dart`): a `CassetteScrubber` widget
   wrapping the playback `Slider` in a `SliderTheme` with two custom
   shapes — `_GrooveTrackShape` (dark rounded channel, thin top inset
   highlight) and `_CapstanThumbShape` (tall rounded rectangle, small
   gradient) — sized for a thumb a moving cursor rides. Wired in
   `playback_dashboard.dart` where the `Slider` mounts, in the scope the
   user picks.
4. **Mockup** (`docs/mockups/cassette-buttons.html`): updated to match —
   floating keys, the merged REC/PAUSE key states, the retro scrubber.
5. **Tests** (`test/cassette_style_test.dart`): merged-key states (the
   pause-glyph key latched + blinking while recording; the play-glyph
   key latched + steady while paused); `CassetteDeck` assertions
   removed (the type is gone); scrubber renders in scope.
6. `flutter analyze` clean, `flutter test` green, commit.

## Constraints honored

No new packages (custom shapes are `CustomPainter`s in the app's own
files); no behavior change beyond the merged REC key (which restores the
flat style's single-slot interaction); localized strings unchanged — no
new user-visible text.
