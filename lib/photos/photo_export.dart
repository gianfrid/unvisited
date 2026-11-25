/// The photo export paths: user-initiated ways to get a photo *out* of
/// the app's private storage — Save to gallery (a MediaStore copy) and
/// Share (the system share sheet over the FileProvider). Both are host
/// channel calls on `unvisited/host`; where the channel has no native
/// side (desktop Linux, widget tests) the calls fail with
/// [MissingPluginException] and the callers degrade gracefully. The
/// app's own copy under `photos/` is never touched by either path.
library;

import 'package:flutter/services.dart';

import '../host_channel.dart';

/// The mime of a photo file from its extension (the store sniffs the
/// real type at save time, so the extension is honest).
String photoMimeFor(String file) {
  final ext = file.split('.').last.toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}

/// Copies the photo at [path] into the device gallery
/// (Pictures/Unvisited). True when the gallery accepted it; false on any
/// failure, including a platform with no gallery host (desktop, tests).
Future<bool> savePhotoToGalleryFile(String path, String displayName) async {
  try {
    final ok = await hostChannel.invokeMethod<bool>('savePhotoToGallery', {
      'path': path,
      'displayName': displayName,
      'mime': photoMimeFor(path),
    });
    return ok ?? false;
  } on MissingPluginException {
    return false; // no native side (desktop/test runs)
  } on PlatformException {
    return false; // the host's save_failed / not_found
  }
}

/// Opens the system share sheet for the photo at [path]. The chooser's
/// outcome is the other app's business; failures (no receiver, a gone
/// file) are swallowed — sharing is a fire-and-forget courtesy.
Future<void> sharePhotoFile(String path) async {
  try {
    await hostChannel.invokeMethod('shareFile', {
      'path': path,
      'mime': photoMimeFor(path),
    });
  } on MissingPluginException {
    // No native side (desktop/test runs): nothing to share through.
  } on PlatformException {
    // No app accepts the share, or the file vanished mid-call.
  }
}
