import 'package:flutter/services.dart';

/// Channel to the Android host: storage root, cache dir, SAF folder picks and
/// share-intent temp files. There is no native side on desktop; callers fall
/// back to platform defaults when the methods are missing.
const hostChannel = MethodChannel('unvisited/host');

/// Fires as soon as the Dart side is listening for shared tracks.
const sharedChannel = MethodChannel('unvisited/shared');
