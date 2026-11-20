Implements: TODO.md #2

# Playback scrubber: seek in the engine, draggable slider on the bar

## Goal

A draggable position scrubber on the playback bar: jump to any point of
the replayed track's timeline, marker/trace following while scrubbing.
Two independently committable units, as TODO.md #2 decomposes them:

1. **Engine re-seek** — `lib/playback/track_playback.dart` + unit tests.
   The timeline cursor currently walks forward only (`_syncIndex` is
   monotonic); backwards seeking needs a rewind-capable re-seek.
2. **Bar scrubber** — `lib/ui/playback_dashboard.dart` + widget tests,
   including the follow-camera's behavior while scrubbing.

## Design decisions

- **Seek API on the engine:** `void seekTo(Duration position)` — clamps to
  `[0, total]`, sets `_progressMs`, and re-derives `_index`. The index
  re-derivation is a binary search over the strictly increasing
  `offsetsMs` (`_syncIndex` stays as the forward-only fast path for
  [advance]); a scrub fires many seeks, so O(log n) per seek, not a
  reset-and-walk. `position`, `course`, `playedIndex`, `progressFraction`
  and `finished` are all pure getters over `_progressMs`/`_index`, so
  they are correct immediately after a seek with no extra work.
- **Seek keeps the play state.** Seeking is a position change, not a
  transport change: a playing replay continues from the new position, a
  paused one stays paused. Seeking to the end lands on `finished`
  (derived, not set), so the play button's replay-from-start behavior is
  unchanged. Seeking to 0 does not restart the status — `restart()`
  remains the explicit rewind-and-pause.
- **Controller passthrough:** `PlaybackController.seekTo(Duration)` calls
  `_playback?.seekTo(...)` then `playbackLive.notify()` — the bar, marker
  and trace all rebuild off that channel, so a scrub moves them exactly
  like a tick does. No structural `onChanged` (no layer mounts/unmounts).
- **Scrubber widget:** a `Slider` in the bar's row, between the play
  button and the track name (the row is already `Flexible`-wrapped for
  the name; the slider gets a bounded width via `Expanded` around it or a
  `SizedBox` width — final layout choice at implementation, the bar must
  stay one row on narrow screens). `value = playback.progressFraction`,
  `onChanged` → `model.player.seekTo(total * fraction)`. No `onChangeEnd`
  special-casing: while dragging, each change notifies `playbackLive` and
  the marker/trace follow live. Slider drags do not generate map events,
  so they never touch the follow-camera's gesture release.
- **Follow-camera while scrubbing: stays armed.** A scrub is an intent to
  look at that point of the track, not a pan away — releasing the follow
  would leave the marker jumping off-screen while the map stays put.
  The seek's `playbackLive.notify()` drives the dashboard's existing
  `_onPlaybackTick`, so the follow-camera glides to each scrubbed
  position like any tick (the glide easing already smooths the jumps).
  Re-arm paths are unchanged: the play button's `_armAndFeed()`, a
  gesture release still disarms, a new replay re-arms via the boundary
  detector. This is the decision TODO.md #2 asked to make; the widget
  test pins it.
- **No l10n impact:** the slider needs no text (the elapsed/total readout
  already sits next to it); no new strings.

## Steps

1. **Unit 1 — engine + tests.** Add `seekTo(Duration)` and the binary
   search index re-derivation to `lib/playback/track_playback.dart`
   (keep `_syncIndex` for `advance`). Add `seekTo` to
   `lib/ui/playback_controller.dart` with the `playbackLive.notify()`.
   Unit tests in `test/track_playback_test.dart` (straight-line fixture
   already there): seek forward/backward lands the cursor exactly; clamp
   below 0 and beyond total; `position`/`course`/`playedIndex` correct
   right after a backward seek (the old monotonic index would have been
   stale); seek to end → `finished`, play-after restarts; seek keeps
   paused/playing status; controller test in
   `test/playback_controller_test.dart`: `seekTo` fires `playbackLive`
   and leaves a running replay playing. Run `flutter test` +
   `flutter analyze`. Commit: "Playback: rewind-capable seek in the
   timeline engine (#2)".
2. **Unit 2 — scrubber + widget tests.** Add the `Slider` to
   `lib/ui/playback_dashboard.dart`'s bar row, keyed
   `ValueKey('playback-scrubber')`, wired to `model.player.seekTo`. Widget
   tests in `test/playback_widget_test.dart`: pump a replay, drag the
   slider (or call `onChanged` via the widget) to a fraction, assert the
   engine's elapsed moved and the time readout updated; assert the
   follow-camera stayed armed across a scrub (the decision above) and
   that the marker moved with it. Run `flutter test` + `flutter analyze`.
   Commit: "Playback bar: draggable position scrubber (#2)".
3. **Backlog:** remove TODO.md #2 in the same commit as unit 2 (the item
   is only complete when both units land).

## Non-goals

- No keyboard/arrow-key seeking, no skip-forward/backward buttons.
- No scrubber on the recording dashboard (a live session has no fixed
  timeline to scrub).
- No change to the trace layer's rendering (it already reads
  `playedIndex`/`position` per tick).
