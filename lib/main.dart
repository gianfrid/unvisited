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
  final store = TrackStore(root);
  final model = AppModel(store);
  await model.load();
  _listenForSharedTracks(model);
  runApp(UnvisitedApp(model: model));
}

/// App-private storage: Android's filesDir via the host channel; falls back
/// to a local folder when running on the host/desktop without the channel.
Future<Directory> _resolveStorageRoot() async {
  try {
    final path = await _hostChannel.invokeMethod<String>('getFilesDir');
    if (path != null && path.isNotEmpty) {
      return Directory(path);
    }
  } on MissingPluginException {
    // no host implementation (desktop/tests): use a project-local folder
  } on PlatformException {
    // ignore: treat as absent
  }
  return Directory('.unvisited');
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
  _sharedChannel.invokeMethod('ready');
}

class UnvisitedApp extends StatelessWidget {
  const UnvisitedApp({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unvisited',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4363D8),
        useMaterial3: true,
      ),
      home: MapPage(model: model),
    );
  }
}
