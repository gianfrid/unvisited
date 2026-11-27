# Peek pan: one-finger drag pans and returns on lift while recording

Implements: —

## Problem

The previous slice's drag lock made one-finger drags inert while a
session's follow-camera is armed — honest about blocking accidents, but
zero feedback: a deliberate one-finger pan reads as a broken map. The
better mechanics: let the hand pan (live feedback), and when the finger
lifts, the camera glides back to the fix framing on its own. Accidental
touches still heal themselves (now visibly), and look-around stays
deliberate through the two-finger release.

## Design

While `isRecording && followArmed` ("peek mode"):

| Gesture | Recording, follow armed (peek mode) | Recording, follow released | Idle / playback |
|---|---|---|---|
| One-finger drag | Pans live (a *peek*); fixes are held while the finger is down; on lift the camera glides back to the latest fix framing; fling momentum off (lift = return, nothing fights the glide) | Pan freely (unchanged) | Pan freely; releases the follow (unchanged) |
| Two-finger pan / pinch / twist | Works; releases the follow (+ toast, unchanged) | Works | Works (unchanged) |
| Long-press | Re-arms / re-centers (unchanged) | Same | Unchanged |
| Fix arrives | Held while peeking; latest target stored for the return | Camera stays put | — |

The follow never flips during a peek: no release, no toast, the pill's
locate slot stays retired — there is nothing to recover from, the
return is automatic.

### Non-goals

- Playback keeps today's release-on-drag (a replay is watched
  deliberately; the peek policy is the session's). Possible follow-up
  if the same annoyance shows up there.
- No distance/time threshold that "promotes" a long peek to a release —
  the escape hatch stays the two-finger gesture.

## Mechanics (verified against follow_camera.dart and flutter_map 8.3.2)

- The map flags while armed drop only `flingAnimation` now (`drag` is
  back on). The fling bit off also keeps the phantom
  fling-not-started-sourced-`dragEnd` event away, so the drag's own
  events (`moveStarted(dragStart)` → `dragUpdated(onDrag)` →
  `moveEnded(dragEnd)`) are the only drag events the follow sees.
- `FollowCamera` gains a mutable `dragPeeks` flag (default false), set
  by the recording dashboard at both `reset()` sites (the
  rebuilt-widget re-arm and the session-boundary handler), and a
  `_peeking` state:
  - `dragStart` while armed and `dragPeeks` → `_startPeek()`: stop any
    in-flight glide (the hand owns the camera), store a home target
    from the last fix so a short peek (no fix during it) still has
    somewhere to return, and hold the glide ticker while peeking.
  - `onDrag` while peeking → ignored (no release, no zoom adoption — a
    pure drag changes no zoom anyway).
  - Per-fix `update()` while peeking → stores the fresh target without
    starting the ticker (a target must never pull against the hand).
  - `dragEnd` while peeking → `_endPeek()`: start the glide ticker on
    the freshest stored target — the ~350 ms tau glide back, rotation
    included, identical to the normal follow glide.
  - `multiFinger*`/`doubleTap`/`wheel` sources → clear the peek and
    release as today (a second finger landing mid-peek starts
    `multiFingerGestureStart`, which releases — the escape hatch).
  - `reset()` clears the peek (session boundaries never leak state).
- No session fix yet + peek + lift → nothing to return to; the camera
  waits for the first fix, which glides it in (arm is untouched).

## Steps

1. **FollowCamera** (`lib/ui/follow_camera.dart`): add `dragPeeks`,
   `_peeking`, `_lastPoint` (stored by every `update()`); the listener
   branches above; `_setGlideTarget` holds the ticker while peeking;
   `_startPeek`/`_endPeek`; `reset` clears the peek.
2. **Recording dashboard** (`lib/ui/recording_dashboard.dart`): set
   `follow.dragPeeks = recording` at the two `reset(armed: …)` sites.
3. **MapPage** (`lib/ui/map_page.dart`): the armed-state flags drop only
   `~InteractiveFlag.flingAnimation` (drag restored); comment updated.
4. **SPEC.md**: revise the deliberate-camera invariant bullet — a
   one-finger drag while following is a peek that pans and returns on
   lift (fling momentum off), two fingers release, long-press re-arms.
5. **Tests** (`test/map_page_test.dart`):
   - Replace 'while the follow is armed, a one-finger drag is inert
     during a recording' with the peek semantics: the drag pans, no
     toast, the follow stays armed, and after the glide the camera is
     back on the fix framing.
   - New: a fix arriving mid-peek does not yank the camera while the
     finger is down; after lift it returns to the *new* fix framing.
   - The five two-finger release tests, the long-press, toast, and
     reposition-guard tests are unchanged (two-finger still releases).

## Verification

- `flutter analyze` clean; `flutter test` green (offline run).
- No new packages; no FollowCamera signature changes (both dashboards
  compile untouched apart from the flag assignment).

## Commit

One slice, one commit: plan file, follow-camera peek, dashboard flag,
MapPage flags, SPEC revision, test rework and additions.
