# Slice 14 — a paused recording's timer must not count the pause

## Context

`RecordingSession.elapsed` is `lastAcceptedFix − firstAcceptedFix` on the
fix timestamps. Paused fixes are ignored, so on resume the first accepted
fix's gap spans the entire pause and the dashboard's elapsed jumps by
every paused second. Moving time has the same hole for the resumed fix's
gap. The engine doc already states the right semantics for distance — "a
pause or fix loss is a jump, not distance"; elapsed and moving time must
read the same way: time inside a gap that crosses a segment break counts
nowhere.

## Steps

1. `lib/recording/recording_session.dart`:
   - replace the `last − first` getter with an accumulator
     `_elapsedMillis`, fed by each accepted non-first fix's gap;
   - in `processFix`, determine whether the gap crosses a segment break
     (`gap > segmentGap` — a pause is `breakSegment()`d immediately, a
     fix-loss gap breaks by the same threshold); when it does, neither
     elapsed nor moving time counts that gap;
   - the paused session needs no timer: no fixes are accepted, the
     accumulator sits still — freeze for free;
   - drop the now-unused `_firstFix`/`last − first` machinery; update the
     class doc's elapsed/moving-time sentence.
   - distance keeps its existing behavior (the jump is counted as
     traveled meters — explicitly out of this slice's scope).
2. Tests (`test/recording_session_test.dart`):
   - two fixes 1 s apart, a pause, a resume, then fixes timestamped after
     the pause: elapsed stays the run time only (e.g. 2 s, not 62 s);
     moving time likewise when the fixes move;
   - elapsed freezes at the last value while paused (no ticking);
   - a second pause/resume behaves the same;
   - the existing pause/resume segment test keeps passing (only timer
     semantics change there, and its final assertions don't read
     elapsed).

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md and deletes the slice 14 TODO entry; PLAN.md
  carries over to the next task unmodified.
