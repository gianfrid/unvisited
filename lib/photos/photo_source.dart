/// The camera-capture port: the model captures photos through this
/// interface and nothing else, so the capture stays unit-testable with a
/// fake source — the same seam `PositionSource` cuts for location.
/// The real source (`ImagePickerPhotoSource`) launches the system camera
/// app via image_picker; Android only, and deliberately without any
/// runtime permission (no CAMERA permission is declared, which is what
/// lets image_picker's intent path work undeclared).
library;

/// What one capture attempt produced. A sealed family so consumers
/// switch over it exhaustively — the shape `ImportOutcome` uses for the
/// import paths.
sealed class PhotoCaptureOutcome {
  const PhotoCaptureOutcome();
}

/// The camera app returned an image; [bytes] carry it as captured.
final class PhotoCaptureSucceeded extends PhotoCaptureOutcome {
  const PhotoCaptureSucceeded(this.bytes);

  final List<int> bytes;
}

/// The user backed out of the camera app (or no camera app exists):
/// expected, not an error.
final class PhotoCaptureDeclined extends PhotoCaptureOutcome {
  const PhotoCaptureDeclined();
}

/// The capture failed on the platform side (picker crash, unreadable
/// result). The UI surfaces a failure message, not a stack trace.
final class PhotoCaptureFailed extends PhotoCaptureOutcome {
  const PhotoCaptureFailed(this.reason);

  final String reason;
}

/// The capture seam itself. One method: take a photo, hand back the
/// bytes or why there are none.
abstract class PhotoSource {
  Future<PhotoCaptureOutcome> capture();
}
