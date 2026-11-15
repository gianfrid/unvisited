<!-- Open work lives here; completed items are deleted, not ticked. -->

1. Recording notification stays open after the session is stopped — `RecordingSession.start` subscribes to the position stream but nothing cancels the subscription on stop/discard, so geolocator's foreground service (and its ongoing notification) keeps running after Stop.
   1. Cancel the stream subscription in `RecordingSession.stop` (store the `StreamSubscription` from `start`), so the foreground service and its notification end with the session; covers `discardRecording` too.
   2. Unit test: after `stop`, delivered fixes are no longer processed.
   3. Manual verification on Android: the "Recording" notification is gone after Stop and after Discard.
