# PLAN — Locate usable while recording

TODO unit: "Recording — map controls & camera", item 1.

Goal: while a recording session runs (recording or paused), the Locate
button is usable to return where the user is — after panning the map away —
by re-centering on the session's current fix and re-arming the follow-camera
(which any gesture release had turned off, together with the course-up
rotation). Not a second GPS attempt: the foreground service's own fix is
fresher, and permission is already granted.

## Design

- `_locate()` gains a shortcut branch before the locate attempt: when
  `widget.model.isRecording` and the session reports a fix
  (`currentLat`/`currentLon` non-null), set `_followRecording = true` and
  move the camera onto the fix at the *current* zoom (the follow preserves
  the zoom; the locate's never-zoom-out `_locateZoom` branch would fight the
  user's detail level). Return before `_locating` is set — the shortcut is
  instant, no spinner. A paused session keeps its last fix, so a paused tap
  returns to the last known position.
- While a session runs but has no fix yet (cold GPS): fall through to the
  normal locate attempt. On its success, arm `_followRecording = true` too
  (in the same setState as `_locatedPosition`), and keep the camera at the
  user's zoom — the follow takes over from there. On its failure, the
  existing toast path says why and the follow stays released.
- Toolbar gate: the Locate action is currently hidden while recording
  (`locationSupported && !model.isRecording`). Drop the `!isRecording` half —
  it shows during recording too — and update the toolbar's comment above:
  while a session runs the header keeps Stop, Pause, Locate, Tracks,
  Settings (Import and Fit stay out; Stop/Pause leave the header with the
  planned record-slot slice).
- No `_locatedPosition` "you are here" marker is set from the recording
  branch — the recording marker is authoritative there (the tests pin the
  marker, not the locate one).
- The re-arming move emits controller events (programmatic sources), so it
  never releases the follow it arms. Their zoom carry: `_locate()` keeps the
  rotation wherever the camera has it.

## Implementation steps

1. `lib/ui/map_page.dart`:
   - toolbar gate drops `!widget.model.isRecording` for the Locate action;
     comment updated;
   - `_locate()`: the shortcut branch (session fix → re-arm follow, re-center
     at the current zoom, return); the fall-through success path arms the
     follow when `model.isRecording` and keeps the camera at the user's zoom
     instead of the `_locateZoom` branch;
2. Tests in `test/map_page_test.dart`:
   - record, pan away (the pan releases the follow), assert the Locate
     button is still present in the while-recording toolbar, tap it — the
     camera follows the next fix (recentred on the session fix, zoom kept);
     taps beyond the first at further fixes keep following;
   - record with a session that has produced nothing yet, tap Locate — the
     normal locate attempt answers (the geolocator mock supplies it), the
     follow arms on its success.
   - the locate tap does not leave a spinner when the shortcut took it.
3. Docs — ARCHITECTURE.md (Locate paragraph + dashboard bullet) and SPEC.md
   item 6: while recording, locate returns the follow (re-centers on the
   session's fix, the user's zoom); no new user-visible strings anywhere.
   Remove TODO unit 1 and renumber the section.

## Out of scope for this slice

- The bottom-left action stack (unit 2), pause/resume/stop at the record
  slot (unit 3).

## Verification

`flutter analyze` clean; `flutter test` green; on Android: record, pan away,
tap Locate — the map rides the fixes again.
