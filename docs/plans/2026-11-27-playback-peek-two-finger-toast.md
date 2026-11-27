# Playback peek + the two-finger teaching toast

Implements: —

## Problem / decision

The peek (one-finger drag pans, camera returns on lift; two fingers
release) is recording-only today; during a replay a one-finger drag
still pans freely and releases the follow — the same accidental-touch
exposure the recording was cured of, and the two screens behave
differently for no user-visible reason. Decided with the user:

1. **Playback gets the peek too** — same mechanics, same shared
   `FollowCamera` code path (the "identical by construction" property
   the SPEC claims for the follow-camera extends to the peek).
2. **The two-finger escape is taught with a toast on the first peek's
   return, per session/replay** — on both screens. First-only so
   accidental brushes never spam; the return is the moment the user
   wonders "how do I look around?".

## Design

| Gesture | Recording or replay, follow armed (peek mode) | Follow released |
|---|---|---|
| One-finger drag | pans live; on lift glides back to the latest fix/cursor framing; first peek return toasts the two-finger hint | pans freely (unchanged) |
| Two-finger pan/pinch | releases (+ release toast while recording) | free |
| Long-press | re-arms / re-centers (unchanged) | same |

The map flags while a followed thing rides with the follow armed drop
only `flingAnimation` — the condition extends from `isRecording` to
"session or replay".

## Steps

1. **FollowCamera** (`lib/ui/follow_camera.dart`): add an
   `onFirstPeek` callback and a `_taughtPeek` latch — `_endPeek` fires
   it once; `reset` clears the latch (once per session/replay).
2. **Recording dashboard** (`lib/ui/recording_dashboard.dart`): wire
   `onFirstPeek` to `showMapToast` with the new string (the dashboard
   owns its toast; no MapPage plumbing).
3. **Playback dashboard** (`lib/ui/playback_dashboard.dart`): set
   `follow.dragPeeks = playback != null` at its reset site, and wire
   the same `onFirstPeek` toast.
4. **MapPage** (`lib/ui/map_page.dart`): the armed-state flags
   condition becomes
   `(isRecording || playback != null) && _followArmed`; comments.
5. **Strings** (`lib/l10n/app_strings.dart`): `twoFingerPanHint` —
   EN "Two fingers to pan the map freely", IT "Due dita per muovere
   liberamente la mappa"; registered in `test/app_strings_test.dart`.
6. **SPEC.md**: the deliberate-camera bullet notes the peek applies
   during replays too, and that the first peek return teaches the
   two-finger escape with a toast.
7. **Tests**:
   - Move `twoFingerPan` from `test/map_page_test.dart` to
     `test/helpers.dart` (playback tests need it now).
   - `test/playback_widget_test.dart`: the three one-finger
     release-drags (lines ~509, ~572, ~676) switch to the two-finger
     gesture; new test — a one-finger drag during a replay pans,
     returns on lift (camera not where the hand left it, follow still
     armed), and the first return shows the hint.
   - `test/map_page_test.dart`: the recording peek test's
     `findsNothing` SnackBar assertion becomes the hint expectation
     (the first peek now teaches); new test — the latch: first peek
     return toasts, the snackbar expires, a second peek return does
     not toast again. The reposition-guard test's one-finger release
     drag during the replay switches to the two-finger gesture (the
     one-finger drag is a peek now).

## Verification

`flutter analyze` clean; `flutter test` green (offline). No new
packages; FollowCamera gains one callback field, dashboards one line of
wiring each.

## Commit

One slice, one commit: plan file, follow-camera latch + callback,
dashboard wiring, MapPage flags condition, string, SPEC, tests.
