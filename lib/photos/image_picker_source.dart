import 'dart:io';

import 'package:image_picker/image_picker.dart';

import 'photo_source.dart';

/// The real capture source: image_picker launches the *system* camera
/// app (an intent — no in-app viewfinder, no CAMERA permission, no
/// runtime prompt). A null result is the user backing out; a
/// PlatformException or an unreadable result file is a failure. Only
/// constructed on Android — the camera button is hidden everywhere else
/// (the record cluster's gates), and image_picker ships no desktop
/// implementation anyway.
class ImagePickerPhotoSource implements PhotoSource {
  ImagePickerPhotoSource({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PhotoCaptureOutcome> capture() async {
    final XFile? file;
    try {
      file = await _picker.pickImage(source: ImageSource.camera);
    } on Exception catch (e) {
      return PhotoCaptureFailed(e.toString());
    }
    if (file == null) return const PhotoCaptureDeclined();
    try {
      return PhotoCaptureSucceeded(await file.readAsBytes());
    } on Exception catch (e) {
      return PhotoCaptureFailed(e.toString());
    }
  }
}

/// A source for platforms without a capture path (desktop Linux, tests
/// that inject nothing): captures fail gracefully instead of throwing —
/// the camera button is hidden there anyway, so this only exists so a
/// stray call can never crash the model.
class UnsupportedPhotoSource implements PhotoSource {
  const UnsupportedPhotoSource();

  @override
  Future<PhotoCaptureOutcome> capture() async =>
      const PhotoCaptureFailed('no camera on this platform');
}

/// The model's default capture source: the real camera app on Android,
/// the graceful failure everywhere else. Platform read once per model;
/// the platform cannot change at runtime (the same rule as
/// `locationSupportAvailable` in main.dart).
PhotoSource defaultPhotoSource() =>
    Platform.isAndroid ? ImagePickerPhotoSource() : const UnsupportedPhotoSource();
