# PLAN — Bottom-left action stack (locate + record out of the top bar)

TODO unit: "Recording — map controls & camera", item 1.

Goal: the locate button leaves the top toolbar and sits at the map's
bottom-left corner; the record button sits directly above it and is shown
only once a position fix has been acquired. While recording, the record
slot becomes Stop with Pause in the slot directly above locate (the
pause→resume / stop-with-name rework is the next unit). The top bar keeps
Import / Fit / Tracks / Settings. The Fit button stays for now — its
removal belongs to the aggregate-track unit ("Map — aggregate tracks &
selection" #3), not this slice.

## Design

- Reuse `_HeaderAction` (icon + label pill, same tooltips/labels as today)
  inside a vertical `Column` — consistent with the app's labeled-action
  language, and the existing tests that tap `byTooltip('Record' / 'Pause' /
  'Center on current position')` keep working unchanged.
- Stack placement: `Positioned(left: 12, bottom: 0)` wrapping a `SafeArea`
  (minimum bottom 16) so it clears the gesture bar; column order
  top→bottom: [Record | Stop, Pause] over [Locate]. Idle: Record, Locate.
  Recording: Stop, Pause, Locate (Pause occupies the record slot directly
  above Locate; Stop above it — the next unit's "stop appears before it").
- Gates unchanged: the whole stack is `widget.locationSupported`-only
  (desktop Linux: no stack at all); Record additionally requires
  `_gpsWorking || model.isRecording` (a real fix acquired — the silent
  retry loop still reveals it); Locate keeps its `_locating` spinner.
- The zoom slider on the left edge is vertically centered in the free
  band, so the corner stack does not collide with it on normal screens;
  on very short windows they could come close — accepted, no slider
  change in this slice.
- Top toolbar after the move: Import, Fit, Tracks, Settings when idle;
  Tracks, Settings while recording (Locate stays usable during recording —
  it now lives in the stack, the previous slice's behavior is unchanged).

## Implementation steps

1. `lib/ui/map_page.dart` build: remove the Locate, Record/Stop and
   Pause/Resume `_HeaderAction`s from `_FloatingToolbar`; add the
   bottom-left `Positioned` stack with the same actions, gates and
   handlers (`_locate`, `_startRecording`, `_stopRecording`,
   pause/resume); update the toolbar comment.
2. Tests in `test/map_page_test.dart`:
   - new widget test: with location supported and a fix acquired, the
     Locate and Record actions are in the bottom half of the map,
     left-aligned to the same x, Record directly above Locate (rects);
     the top bar no longer contains them (their rects are below the
     toolbar band);
   - while recording: Stop and Pause are in the stack (bottom half),
     Locate still present; no fix yet → no Record anywhere; desktop
     (`locationSupported: false`) → no stack;
   - existing header tests ('record mode trims the header…', 'no fix yet…',
     the locate-while-recording tests) keep passing — they assert by
     text/tooltip, not position.
3. Docs — ARCHITECTURE.md UI paragraph and the locate/dashboard bullets
   (spinner now on the stack button; record/locate stack bottom-left);
   SPEC.md item 6 one clause. Remove TODO unit 1, renumber the section.

## Out of scope

- Fit removal from the top bar (aggregate-track unit), pause→resume
  transform + stop name dialog (next unit), aggregate selection.
- No new user-visible strings — same labels/tooltips reused.

## Verification

`flutter analyze` clean; `flutter test` green; manual on Android: the
stack hugs the bottom-left, Record appears only after a fix, recording
shows Stop/Pause there while the header keeps Tracks/Settings.
