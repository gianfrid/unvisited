# Recording speed: big readout in the top bar's center, out of the chip

Implements: — (user request, no backlog entry)

## The design (agreed with the user)

While a session runs, the top floating toolbar shows the current speed as
the pill's centered segment, flanked by the two actions it keeps while
recording:

`` [Tracks]   18.2   [Settings] ``, with `` ─ km/h ─ `` as the segment's
caption below the number — the same over-caption cell shape as the
flanking ``HeaderAction``s (which are fixed 48 x kToolbarHeight cells:
icon over a 10 px caption). The number at ``displaySmall`` (~30 px,
w600) inside the pill's kToolbarHeight, so the toolbar's height never
changes. Before the first fix and while paused the number is ``—``
(the chip's existing convention). The small inline speed in the HUD chip
is removed (user's choice: one primary readout); the chip keeps dot,
duration, distance, the rotation button and the chevron — its row height
is unchanged, so the follow-camera's bottom-overlap framing is
untouched.

Width check: recording-time bar = 48 + ~90 + 48 + pill padding ≈
200 px — fits the narrowest tested surface (360) with ~70 px margins;
overflow asserted in the tests.

## Why the mount/update discipline (the 2026-11-19 marker bug)

The segment must not read the session at ``TopToolbar`` build time in any
way that a fix must change: it mounts via the session boundary (start/
stop call ``notifyListeners`` on the model, which rebuilds the page and
with it the toolbar) and its per-fix value comes from a
``ListenableBuilder`` scoped to ``model.recordingLive`` inside the
segment — a 1 Hz fix repaints the segment only. Reading the value at
toolbar build time would freeze it exactly the way the marker froze
(2026-11-19 marker slice).

## Changes

1. ``map_actions.dart`` — ``TopToolbar``: while ``model.isRecording``,
   the pill's children become ``[Tracks][speed segment][Settings]``; the
   Import action stays hidden while recording as today. The segment is
   a new private widget (in ``map_actions.dart`` beside the toolbar):
   ``RecordingSpeedSegment`` — ``ListenableBuilder`` (recordingLive)
   reading ``model.recording?.currentSpeed`` inside the builder; number
   ``18.2``-formatted via the existing ``(m/s * 3.6).toFixed(1)``
   convention; key ``ValueKey('recording-speed')`` (kept — tests move
   with it); caption ``km/h`` in the HeaderAction caption style. Em
   dash for ``null`` speed / paused. No tooltips, no new strings.
2. ``recording_dashboard.dart`` — remove the chip's inline speed
   (``ConstrainedBox`` + ``recording-speed`` usage there) and the
   spacing it carried; chip row = dot, duration, distance, rotation
   button, chevron. Update the chip/segment doc comments.
3. ``map_page.dart`` — the top-band comment above the toolbar paragraph
   updates (the bar carries the recording speed).
4. Tests ``test/map_page_test.dart``:
   - New: while recording the toolbar shows the segment; ``—`` before
     the first fix (after the start frame settles — field timing, as
     the 2026-11-19 marker tests taught) and the live value after a
     fix (per-fix update through the recording-live channel).
   - New: no overflow (``takeException()`` null) with the recording bar
     on the narrowest tested surface 360x740, panel open and closed.
   - Update: the three marker-clears-the-bottom-column surface tests
     drop ``recording-speed`` from the marker-clearance key list (the
     segment is top-band now; ``recording-chip`` / ``stats-panel``
     pairs remain) and any chip-speed assertions change to the
     toolbar's segment.
   - Existing idle-toolbar tests stay green (Import + Tracks + Settings,
     no segment).
5. ``ARCHITECTURE.md`` — the Dashboard paragraph: the headline speed
   lives in the top bar's center while recording (the chip's inline
   speed is gone); double-check the "marker and camera never trail one
   fix behind" line stays accurate.

## Verification

``flutter analyze`` clean; ``flutter test`` green; the new tests red
first where they can be (segment absent on today's tree — the mount
test's post-start-frame ``—`` assertion — proves the discipline is
exercised, not assumed).
