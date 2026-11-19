# Recording marker: mount and position from the per-fix channel, not the page build

Implements: — (bug report from the field, no backlog entry)

## Symptom

The recording marker (the triangle `Icons.navigation` in the disc) still
disappears during recording, on-device, after 79380e3 (which fixed the
HUD-overlap variant: `docs/plans/2026-11-17-recording-marker-fixes.md`).

## Diagnosis

`MapPage._recordingMarkers()` (`lib/ui/map_page.dart`) reads
`session.currentLat` / `currentLon` **at MapPage build time**, outside the
per-fix `ListenableBuilder`:

- If they are null at that build, it returns `const []` — the listenable
  subtree is not even mounted.
- If they are non-null, the mounted builder later rebuilds the marker's
  *rotation* (via `recordingLive` + `_markerRotation`), but its *point* is
  the captured `lat`/`lon`: frozen at whatever MapPage build last ran.

Nothing re-runs MapPage.build per fix — by design, fixes notify only
`AppModel.recordingLive` (`RecordingController.notifyRecordingFix`),
never `notifyListeners()` on the model. The only model-wide notifies during
a session are incidental (road overlay/report changes while riding, pause,
settings). So on-device:

1. At session start the start-nofix build sees `currentLat == null`
   (the first GPS fix arrives ~1 s later) → the marker subtree never
   mounts → **no marker at all**, for as long as no incidental notify
   happens.
2. When an incidental notify does rebuild MapPage mid-ride, the marker
   mounts **frozen at that fix**; the follow-camera then glides along with
   the live fixes, the stale marker slides down under the HUD and off the
   screen → **disappears again**.

Why the existing tests stay green: every marker test feeds its fixes with
`fakeFix()` immediately after `await model.startRecording(...)` and only
then pumps. The added fixes are delivered to the session as microtasks
during the first pump, *before* the frame's build phase rebuilds the
notify-dirtied MapPage — so the start-time `_recordingMarkers()` call sees
a non-null `currentLat` and mounts the marker. Real-stream timing (start
frame first, fix a second later) never does this. All existing assertions
(angle, HUD clearance) are insensitive to a frozen point, so nothing caught
it. The live trace (`_liveTracePolylines`, read inside its builder off
`recordingLive`) and the dashboard HUD follow the correct pattern — only
the marker was left reading at build time.

## Ranked hypotheses (before the fix)

1. **Marker mount/position keyed to MapPage build (primary, statically
   confirmed above).** Prediction: a widget test with real start→fix timing
   never finds `recording-marker-disc` (the subtree was never mounted);
   forced-mounted, its point stays at the mount-time fix while later fixes
   move on.
2. HUD overlap variant on an untested surface (79380e3 covered
   411x915 / 411x800 / 360x740). Prediction: the red-timing test below
   passes once (1) is fixed; only then would a surface-specific overlap
   remain.
3. Paint order (marker under another layer). Prediction: whenever the
   marker is found by (1)'s test, its rect is also hittable — ordering was
   last touched before 7c6bfce and is unchanged by this fix.

A failed (1)-fix would re-rank these; the red tests below distinguish them.

## The red loop

`flutter test test/map_page_test.dart --plain-name "the recording marker"`
— deterministic (fake clock, fake source), seconds, agent-runnable, asserts
the exact user symptom (the icon is gone / left behind while recording).

## Fix

`_recordingMarkers()` mounts on the session boundary alone and reads the
position per fix, mirroring the trace layer's pattern:

- Gate the returned subtree on `widget.model.recording != null` only
  (start/stop notify the model → `MapPage` rebuilds at the boundary; the
  per-fix `ListenableBuilder` then lives as long as the session).
- Read `currentLat` / `currentLon` / `currentCourse` **inside** the
  builder: the point follows every fix; no fix yet renders an empty
  `MarkerLayer`; the pre-fix absence is gone with the same rebuild that
  delivers the first fix.
- Keep `Listenable.merge([recordingLive, _markerRotation])` and the
  existing rotation/course formula unchanged.
- Update the doc comment to state the mount/position discipline (why the
  reads must live inside the builder).

## Regression tests (`test/map_page_test.dart`)

1. **`the recording marker mounts and rides at the session's first fix`**
   — `startRecording` → `pump()` the start frame (real timing: session
   start builds with no fix) → `fakeFix` + 1 s pump → expect
   `recording-marker-disc` found. Red today: nothing mounts per fix.
2. **`the recording marker follows each fix, not the page build`**
   — start frame → first fix → force one incidental model notify
   (`setMapRotation('north')`) so today's code mounts the marker (as it
   does on-device mid-ride) → advance several moving fixes with 1 s
   real-timing pumps → the marker layer's point equals the *last* fix.
   Red today: the point stays frozen at the mount-time fix.

Existing marker tests (rotation easing/on-screen course, HUD clearance)
must stay green.

## Verification

`flutter analyze` clean; `flutter test` green; both new tests red on the
unfixed tree (verified before applying the fix), green after.
