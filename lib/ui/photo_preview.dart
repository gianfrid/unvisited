/// The photo preview dialog: the stored image scaled to fit, its capture
/// time as the caption, and the photo's actions — Save to gallery (a
/// MediaStore copy through the host channel), Share (the system share
/// sheet), and Delete. Delete is two-step, like the recording stop's
/// discard: it removes the app's own file irreversibly, so it asks first.
///
/// The dialog rides the model's notification: deleting closes it (the
/// model rebuilds the page, the photo is gone, the marker unmounts).
library;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../storage/track_store.dart';
import 'app_model.dart';
import 'format.dart';
import 'map_actions.dart' show showMapToast;

class PhotoPreviewDialog extends StatelessWidget {
  const PhotoPreviewDialog({
    super.key,
    required this.model,
    required this.photo,
  });

  final AppModel model;
  final StoredPhoto photo;

  /// The dialog's result: 'reposition' when its Reposition action was
  /// tapped (the page then arms tap-to-move mode), null otherwise.
  static const repositionResult = 'reposition';

  /// Delete: two-step — the confirm dialog first, then the removal.
  Future<void> _delete(BuildContext context) async {
    final strings = AppStrings.ofContext(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.photoDeleteConfirmTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const ValueKey('photo-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.photoDelete),
          ),
        ],
      ),
    );
    if (context.mounted && confirmed == true) {
      await model.deletePhoto(photo);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  /// Gallery export: a user-initiated MediaStore copy; on platforms with
  /// no gallery host (desktop, tests) the channel call fails and the
  /// toast says so. The stored photo is untouched either way.
  Future<void> _saveToGallery(BuildContext context) async {
    final strings = AppStrings.ofContext(context);
    final ok = await model.savePhotoToGallery(photo);
    if (context.mounted) {
      showMapToast(
        context,
        ok ? strings.photoSavedToGallery : strings.photoSaveFailed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final file = model.store.photoFileFor(photo);
    return AlertDialog(
      title: Text(strings.photoTakenAt(formatDateTime(photo.takenAt))),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 420),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          // The app owns the file under photos/; the preview reads it
          // directly — the image never leaves private storage to be seen.
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('photo-reposition'),
          onPressed: () => Navigator.of(context).pop(repositionResult),
          child: Text(strings.photoReposition),
        ),
        TextButton(
          key: const ValueKey('photo-save-to-gallery'),
          onPressed: () => _saveToGallery(context),
          child: Text(strings.photoSaveToGallery),
        ),
        TextButton(
          key: const ValueKey('photo-share'),
          onPressed: () => model.sharePhoto(photo),
          child: Text(strings.photoShare),
        ),
        TextButton(
          key: const ValueKey('photo-delete'),
          onPressed: () => _delete(context),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          child: Text(strings.photoDelete),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
      ],
    );
  }
}
