# PLAN: Stop button visible while recording, not only after Pause

TODO.md item: "Stop button visible while recording, not only after
Pause".

## Current state

In `lib/ui/map_page.dart`, the bottom-left action stack renders the Stop
action only when the session is paused:

    if (widget.model.recording?.state == RecordingState.paused)
      HeaderAction(icon: Icon(Icons.stop), ..., onTap: _stopRecording),

So while actively recording the only exit is Pause -> Stop (two taps).
`lib/ui/recording_controller.dart` and `lib/ui/recording_live.dart`
need no change: `_stopRecording` already works from any session state
(it asks for the track name, then finalizes or discards).

## Change

1. `lib/ui/map_page.dart`: widen the Stop gate from
   `recording?.state == RecordingState.paused` to `isRecording`, so Stop
   sits above the Pause/Resume slot in both the recording and paused
   states. Order in the stack: Stop first, then the record/pause/resume
   slot, then Locate (unchanged).
2. `test/map_page_test.dart`: update the four tests that pin the old
   "stop only appears once paused" behavior:
   - 'record action starts a session the chip shows and stops it'
   - 'record mode trims the header and shows the speed readout'
   - 'the pause action flips to resume and back'
   - 'locate and record live in the bottom-left stack, not the top bar'
   Each now expects Stop present while recording and while paused.
3. Remove the completed entry from TODO.md.

## Verification

- `flutter analyze` clean.
- `flutter test`: all tests pass, including the updated widget tests
  (Stop's position in the stack is asserted relative to the Pause/Resume
  slot, which keeps the geometry contract intact).
