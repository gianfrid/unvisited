# Deliberate camera control while recording

Implements: —

## Problem

While a session records, the follow-camera rides each fix — but any move
gesture releases it permanently (`FollowCamera._moveGestures`), and the map
runs with `InteractiveFlag.all`. A one-finger brush (glove, handlebar mount,
pocket) silently disengages the follow and the camera stays where the hand
left it; the only ways back are the pill's Locate slot or toggling
course-up, and nothing signals the loss.

## Review findings (verified against flutter_map 8.3.2 and the current code)

- Live flag flips are supported: `MapInteractiveViewer.updateGestures`
  recreates the gesture recognizers when the drag bit flips, and drag
  handling re-checks `InteractiveFlag.hasDrag` per event. A state-computed
  `InteractionOptions.flags` (dropping the current `const`) is enough.
- `InteractiveFlag.drag` is exactly the one-finger pan. `pinchMove`,
  `pinchZoom`, `rotate`, `doubleTapZoom`, `scrollWheelZoom` are separate
  bits, so two-finger pan/zoom/twist, double-tap zoom and the wheel keep
  working while `drag` is off.
- In-flight gestures do not survive a flag flip (recognizers are
  recreated). A "mid-gesture unlock" (raw `Listener` measures the drag,
  releases follow, re-enables drag mid-pan) is therefore rejected: the
  pointer is dropped and the user must lift and drag again — undiscoverable.
- `MapOptions.onLongPress` exists and is currently unused — free for the
  re-arm gesture. `_rearmActiveFollow()` in `MapPage` is exactly the right
  dispatch (session → recording dashboard, replay → playback dashboard).
- `MapPage` already rebuilds on follow flips: both dashboards are handed
  `onFollowChanged: () => setState(() {})`, and `_followArmed` reads the
  dashboards' state during build. The flags computation slots straight in.
- **Dropped from the brainstormed combo: the magnitude threshold.** With
  one-finger drag blocked while armed, every remaining release source
  (pinch, twist, double-tap zoom, fling, wheel) is inherently deliberate;
  a pointer-travel accumulator would be dead weight. Peek/auto-return
  (yanks the camera during deliberate map reading) and a full lock toggle
  (the drag drop already is a lock whose escape hatch is deliberate) are
  likewise dropped.

## Design

While `isRecording && _followArmed`, the map drops the `drag` and
`flingAnimation` bits (the latter matters: flutter_map ends every
one-finger gesture by emitting a fling-not-started event *sourced
`dragEnd`* when the fling bit is on, which the follow-camera's
release-on-gesture-source would read as the hand — the lock would leak
releases through a phantom event). The fling is drag momentum anyway:
without drags it has nothing to animate.

| Gesture | Recording, follow armed (locked) | Recording, follow released | Idle / playback |
|---|---|---|---|
| One-finger drag | **No-op: camera cannot move, follow stays armed** | Pan freely | Pan freely (unchanged) |
| Two-finger pan / pinch / twist | Works; releases follow (+ toast) | Works | Works; releases follow (unchanged) |
| Double-tap zoom | Works; releases follow (unchanged semantics) | Works | Works |
| Long-press | Re-arms follow, re-centers on the fix | Same | Playback: re-arms replay follow; idle: no-op |
| Fix arrives | Glide to the framed fix (unchanged) | Camera stays put | — |

The accidental case — a single-finger touch of any size — becomes a
complete no-op: nothing moves, nothing releases, no recovery needed.
Deliberate look-around stays one gesture (two fingers), and the way back
is one gesture too (long-press anywhere, or the pill's Locate slot, which
already reappears when the follow drops).

### Non-goals

- Double-tap-zoom and scroll-wheel still *release* the follow (today's
  `_moveGestures` semantics) even though they are zoom-only; keeping the
  follow armed through them would change the shared `FollowCamera` for
  playback too. Flagged as a possible follow-up, out of this slice.
- Playback look-around is untouched: the lock is recording-only (a desktop
  replay has no two-finger pan — locking there would strand the mouse).
  Long-press re-arm does extend to playback via the shared dispatch.
- Desktop is unaffected (recording is Android-only).

## Steps

1. **Lock one-finger drag while armed** (`lib/ui/map_page.dart`): replace
   the `const InteractionOptions` with a computed one —
   `flags: widget.model.isRecording && _followArmed
   ? InteractiveFlag.all & ~InteractiveFlag.drag & ~InteractiveFlag.flingAnimation
   : InteractiveFlag.all`, keyboard options unchanged. The build already
   re-runs on follow flips, so the lock engages and releases with the
   follow state without further wiring.
2. **Long-press re-arms** (`lib/ui/map_page.dart`): add
   `onLongPress: (position, latLng) => _onMapLongPress()` to `MapOptions`.
   `_onMapLongPress` returns immediately while `_repositioningPhoto !=
   null` (a session start cancels the reposition banner, but a replay
   start does not — during a replay the banner and the active
   follow-camera genuinely coexist, and a re-centering camera would
   fight the very next pin-placing tap), else calls
   `_rearmActiveFollow()`.
3. **Release toast while recording** (`lib/ui/map_page.dart`): extract a
   shared `_onFollowFlip()` method used by both dashboards'
   `onFollowChanged` callbacks. It tracks the previously seen armed state
   in a `bool?` field and, on a true→false edge while
   `widget.model.isRecording`, shows `showMapToast` with the new
   `followReleasedHint` string. The session-end `reset(armed: false)` is
   naturally suppressed — `isRecording` is already false when that flip
   lands. No `FollowCamera` change at all.
4. **Strings** (`lib/l10n/app_strings.dart`): add `followReleasedHint` to
   the abstract class plus English ("Camera free — long-press the map to
   re-center") and Italian ("Camera libera — tieni premuta la mappa per
   ricentrare"); register the key in `test/app_strings_test.dart`'s
   `allStrings` so the coverage test enforces both translations.
5. **SPEC.md**: one sentence in the Recording invariants noting that
   while a session follows, a one-finger drag is inert and camera control
   is deliberate (two-finger to look around, long-press to re-center).
6. **Tests** (`test/map_page_test.dart`; recording cannot run on desktop
   Linux, so the widget tests carry the verification). The two-finger
   gesture helper starts the pointers a hand-width apart and moves them
   in small interleaved steps — big lockstep jumps read as span/angle
   noise to flutter_map's pinch math, which cancels the pan:
   - Update 'the recording camera follows the fixes; a pan releases it'
     and 'while recording the camera rotates course-up; a pan releases
     it' (plus the other pan-release sites) to release with the
     two-pointer gesture instead of `tester.dragFrom`.
   - New: while recording and armed, a one-finger drag moves the camera
     zero, keeps the follow armed and shows no toast (the next fix still
     glides it).
   - New: after a two-finger release, a one-finger drag pans freely again
     (the lock follows the armed state).
   - New: long-press re-arms the released follow and re-centers on the
     session fix.
   - New: the release during a recording shows the toast once.
   - New: long-press during photo reposition (a replay running, the
     banner armed — the reachable combination) does nothing: no camera
     move, the banner survives, the pin stays put.
   - Existing wheel/zoom-adoption tests are untouched (wheel keeps
     working and still releases).

## Verification

- `flutter analyze` clean, `flutter test` green (offline run).
- No new packages; everything lands in existing files plus the two
  string entries and the SPEC sentence.

## Commit

One slice, one commit: plan file, map_page lock + long-press + toast,
strings, SPEC sentence, updated and new tests.
