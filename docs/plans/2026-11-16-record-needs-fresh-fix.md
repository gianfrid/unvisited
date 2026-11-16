# Record button requires a fresh position fix (TODO.md #3)

Implements: TODO.md #3

## Problem

`_gpsWorking` (which reveals the Record button) is set by any `locate()`
success. Android's fused provider can return a stale cached fix from
`getCurrentPosition`, so Record can appear with no real current position —
and a session started that way shows no direction marker until its first
accepted fix.

## Plan

1. `lib/ui/app_model.dart`, `locate()`: after a successful
   `getCurrentPosition`, reject the fix when its `timestamp` is older than
   `freshFixMaxAge` (30 s — fixes stream at 1 Hz while GPS works, and the
   silent retry loop is 30 s, so anything older is a cache artifact). A
   stale fix returns `LocateResult.failure(LocationFailure.unavailable)`
   (no new enum member/string: "location unavailable" is the honest
   answer). Both `_gpsWorking` paths in `map_page.dart` (silent poll,
   locate button) flow through `locate()`, so Record — and the
   "you are here" marker — now require a genuinely fresh fix.
2. Tests:
   - `test/helpers.dart` `mockGeolocator`: return a fresh
     `DateTime.now().millisecondsSinceEpoch` timestamp by default (it
     currently hardcodes epoch 0, which would read as infinitely stale),
     plus an opt-in `staleFix: true` that returns an old timestamp.
   - `test/map_page_test.dart`: stale fix via the silent poll -> Record
     stays hidden; stale fix via the Locate button -> failure toast,
     Record stays hidden, no marker; existing fresh-fix tests unchanged.
3. Verify: `flutter analyze` clean, `flutter test` passes; commit the plan,
   the change, and remove TODO.md #3 in the same commit.
