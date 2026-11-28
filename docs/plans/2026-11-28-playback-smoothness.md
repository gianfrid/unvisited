# Smoother replay cursor at high speeds + timer centered with the seek bar

Implements: —

## Diagnosis

1. **The jiggle at 32x/64x has two sources.**
   - The replay tick is a `Timer.periodic(50ms)` owned by `MapPage`
     (`lib/ui/map_page.dart`): ~20 fps, not vsync-aligned, and each tick's
     wall delta varies because the UI thread is busy rebuilding the marker,
     trace and bar on the previous tick. At 32x/64x one frame moves the
     cursor 1.6–3.2 s of timeline, so the marker crosses several GPS
     segments per frame and visibly jumps corner to corner.
   - `TrackPlayback.advance` (`lib/playback/track_playback.dart`) truncates
     the wall delta to whole milliseconds *before* scaling
     (`wallDelta.inMilliseconds * speed`) and stores `_progressMs` as an
     `int`. At 64x the sub-millisecond loss is amplified 64x per tick and
     varies tick to tick, so the per-frame step sizes wobble even when
     frames are evenly spaced.
2. **The timer is not centered with the seek bar**: the elapsed/total text
   sits in the identity row next to the track name
   (`lib/ui/playback_dashboard.dart`), not under the scrubber.

## Changes

1. `lib/playback/track_playback.dart` — sub-millisecond precision, no
   behavior change:
   - `_progressMs` becomes a `double` (timeline milliseconds); `advance`
     scales `wallDelta.inMicroseconds * speed / 1000` and accumulates
     without truncation, clamped to `[0, offsetsMs.last]`.
   - `elapsed` reads `Duration(milliseconds: _progressMs.round())`;
     `seekTo`, `finished`, `progressFraction`, `_syncIndex`,
     `_indexOfAtOrBefore` and `position` compare against the double
     directly. All existing test values are exact in double math, so the
     engine tests pass unchanged.
2. `lib/ui/map_page.dart` — vsync-driven tick instead of the 50 ms timer:
   - `_MapPageState` gains `SingleTickerProviderStateMixin`; the
     `Timer? _playbackTimer` is replaced by a page-owned
     `AnimationController _playbackTicker` whose listener is the same
     `_playbackTick` (still wall-clock deltas via `DateTime.now()`, still
     capped at `_playbackTickMaxDelta` = 500 ms). Page-owned as before — a
     ticker the page listens to, never a model-held timer.
   - `_updatePlaybackTimer` becomes `_updatePlaybackTicker`: `repeat()`
     when playing (guarded by `isAnimating`), `stop()` when not; the
     controller is disposed in `dispose()`. Call sites (`_onPlaybackLive`,
     `_onModelChanged`) unchanged.
   - Result: the cursor repaints at display refresh (60/120 fps) — at 64x
     a frame moves ~1 s of timeline instead of 3.2 s, and with change 1
     the steps are even.
3. `lib/ui/playback_dashboard.dart` — center the timer with the scrubber:
   - Row 1's `Expanded(Slider)` becomes `Expanded(Column(min: [Slider,
     timer text]))`; the elapsed/total `Text` moves out of the identity
     row into that column (centered under the seek bar), keeping its style
     (bodySmall, onSurfaceVariant, tabular figures).
   - The identity row keeps the track name on the left and the instant
     speed + speed chip on the right; the `_bar` doc comment is updated.
4. Verification: `flutter analyze` clean, `flutter test` green (no test
   edits expected — widget tests locate the timer via
   `textContaining('/ 00:30')` and the engine tests use exact values).
