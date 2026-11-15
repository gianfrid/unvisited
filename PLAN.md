# PLAN: Recording timer excludes paused time (TODO.md item 2)

TODO.md item: "Recording timer excludes paused time — after pause +
resume, paused seconds still leak into the elapsed (and moving) total
when the pause is shorter than the 30 s segment gap."

One commit: the engine fix + unit tests, PLAN.md, and removal of the
TODO.md entry. Verification: `flutter analyze` clean, `flutter test`
all pass.

## Current state

- `lib/recording/recording_session.dart`, `processFix`: the gap between
  the last pre-pause fix and the first post-resume fix is computed
  against `_lastFix` (the pre-pause fix) and added to `_elapsedMillis` /
  `_movingMillis` whenever `gap <= segmentGap` (30 s). Pauses shorter
  than 30 s therefore leak into the timer; pauses longer than 30 s are
  already excluded because `brokeSegment` (gap > segmentGap) skips the
  accrual.
- `pause()` calls `stage.breakSegment()` and sets `_segmentOpen = true`;
  `resume()` only flips state back to `recording`. Nothing marks the
  next gap as spanning parked time.
- `test/recording_session_test.dart` only exercises long pauses (900 s,
  600 s), so the leak is untested. The class doc and the `_elapsedMillis`
  comment already state the intended rule ("a paused minute ticks
  nowhere") — the code just does not implement it for short pauses.

## The fix

In `processFix`, capture whether this fix opens a fresh segment because
of a pause, before `_segmentOpen` is consumed:

```dart
final brokeSegment = !first && gap > segmentGap;
// A pause arms a fresh segment: the gap bridging a resume spans parked
// time and counts nowhere, whatever its length.
final resumedAfterPause = !first && _segmentOpen;
```

Then change the accrual guard from `if (gap <= segmentGap)` to
`if (!brokeSegment && !resumedAfterPause)` — a gap counts only when it
stays inside one continuous segment. For fix-loss gaps this is
equivalent to the old guard (`brokeSegment` implies `gap > segmentGap`);
for pause-resume gaps of any length it now excludes the parked time.

No changes to distance (the step across a pause is still bridged —
pinned by the existing 'pause/resume breaks the track into two segments'
test and not part of the reported bug), to segment splitting, to
speed/course, or to doc comments (they already describe the intended
behavior).

## Steps

1. Edit `processFix` in `lib/recording/recording_session.dart` as above.
2. Add unit tests in `test/recording_session_test.dart`:
   - a short pause (< 30 s) then resume: elapsed and moving time count
     only the riding seconds, not the parked ones;
   - a short pause mid-ride followed by normal riding: the total
     equals the sum of the riding stretches;
   - keep all existing pause tests passing unchanged (long pauses).
3. Run `flutter analyze` (must be clean) and `flutter test` (all pass).
4. Commit: `recording_session.dart` + `recording_session_test.dart` +
   PLAN.md + removal of TODO.md item 2.

## Out of scope

- Distance bridging across a pause/resume (existing tests pin the
  current behavior; not the reported bug).
- `currentSpeed` on the first post-resume fix (transient, one fix).
- Any change to `segmentGap` semantics or the GPX staging format.
