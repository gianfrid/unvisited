# TODO unit 3: live trace age fade

The recording track fades with age: points bucketed into 30 s buckets,
alpha scaling linearly from the full trace color to 10% over 5 minutes,
so a retreated stretch is almost transparent and direction stays
readable.

## Change
- `recording_session.dart`: new `liveSegmentTimes` getter — per-point
  timestamps mirroring `liveSegments` one to one.
- `map_page.dart`: `_liveTracePolylines()` renders the live trace in
  age buckets with `traceFadeWindow` = 5 min, `traceFadeMinAlpha` = 0.1.

## Tests
- recording_session_test: liveSegmentTimes mirrors segments/points.
- map_page_test: live trace renders recording-red and (with the fake
  fixes' old timestamps) dimmed below full alpha by the fade.

## Verification
analyze clean, 307+ tests pass; commit PLAN.md + change + TODO removal.
