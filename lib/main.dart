import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'storage/track_store.dart';
import 'ui/app_model.dart';
import 'ui/map_page.dart';

/// Channel to the Android host: storage root + incoming share intents.
const _hostChannel = MethodChannel('unvisited/host');
/// Fires as soon as the Dart side is listening for shared tracks.
const _sharedChannel = MethodChannel('unvisited/shared');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await _resolveStorageRoot();
  final cacheDir = await _resolveCacheRoot();
  final store = TrackStore(root);
  final model = AppModel(store);
  await model.load();
  _listenForSharedTracks(model);
  runApp(UnvisitedApp(model: model, cacheDir: cacheDir));
}

/// App-private storage. Android: the host channel's `filesDir`.
/// Desktop (Linux dev runs): the XDG data home. Last resort: a local folder.
Future<Directory> _resolveStorageRoot() async {
  try {
    final path = await _hostChannel.invokeMethod<String>('getFilesDir');
    if (path != null && path.isNotEmpty) {
      return Directory(path);
    }
  } on MissingPluginException {
    // no host implementation (desktop run): fall through to XDG below
  } on PlatformException {
    // host error: fall through, storage choice is not fatal
  }
  final env = Platform.environment;
  final dataHome = env['XDG_DATA_HOME'] ??
      (env['HOME'] != null ? '${env['HOME']}/.local/share' : null);
  if (dataHome != null) return Directory('$dataHome/unvisited');
  return Directory('.unvisited'); // a last-resort folder next to the app
}

/// Cache directory for storing offline map tiles.
/// Android: uses the app's cache directory.
/// Desktop (Linux dev runs): uses XDG cache home. Last resort: a local folder.
Future<Directory> _resolveCacheRoot() async {
  try {
    final path = await _hostChannel.invokeMethod<String>('getCacheDir');
    if (path != null && path.isNotEmpty) {
      return Directory(path);
    }
  } on MissingPluginException {
    // no host implementation (desktop run): fall through to XDG below
  } on PlatformException {
    // host error: fall through, storage choice is not fatal
  }
  final env = Platform.environment;
  final cacheHome = env['XDG_CACHE_HOME'] ??
      (env['HOME'] != null ? '${env['HOME']}/.cache' : null);
  if (cacheHome != null) return Directory('$cacheHome/unvisited');
  return Directory('.unvisited_cache'); // a last-resort folder next to the app
}

void _listenForSharedTracks(AppModel model) {
  _sharedChannel.setMethodCallHandler((call) async {
    if (call.method == 'sharedTrack') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final path = args['path'] as String?;
      final name = args['name'] as String?;
      if (path != null) await model.importFromFile(path, name: name);
    }
  });
  // The channel only has a native side on Android; on desktop there is
  // nothing to listen for share intents, so a missing handler is expected.
  _sharedChannel.invokeMethod('ready').catchError((_) {});
}

class UnvisitedApp extends StatelessWidget {
  const UnvisitedApp({super.key, required this.model, required this.cacheDir});

  final AppModel model;
  final Directory cacheDir;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unvisited',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4363D8),
        useMaterial3: true,
      ),
      home: MapPage(model: model, cacheDir: cacheDir),
    );
  }
}
