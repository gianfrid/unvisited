import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'build_version.dart';
import 'host_channel.dart';
import 'l10n/app_strings.dart';
import 'storage/track_store.dart';
import 'ui/app_model.dart';
import 'ui/map_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await _resolveStorageRoot();
  final cacheDir = await _resolveCacheRoot();
  final hostBuildTime = await _resolveHostBuildTime();
  final store = TrackStore(root);
  final model = AppModel(store);
  await model.load();
  _listenForSharedTracks(model);
  runApp(
    UnvisitedApp(
      model: model,
      cacheDir: cacheDir,
      versionFuture: AppVersion.resolve(hostBuildTime: hostBuildTime),
      locationSupported: locationSupportAvailable,
    ),
  );
}

/// Whether this platform has a location plugin at all. geolocator ships
/// Android/iOS/macOS/Windows/web implementations; desktop Linux has none,
/// so a location fix can never be obtained there and the locate action is
/// pointless. Read once at startup: the platform cannot change at runtime.
final bool locationSupportAvailable = !Platform.isLinux;

/// App-private storage. Android: the host channel's `filesDir`.
/// Desktop (Linux dev runs): the XDG data home. Last resort: a local folder.
Future<Directory> _resolveStorageRoot() async {
  try {
    final path = await hostChannel.invokeMethod<String>('getFilesDir');
    if (path != null && path.isNotEmpty) {
      return Directory(path);
    }
  } on MissingPluginException {
    // no host implementation (desktop run): fall through to XDG below
  } on PlatformException {
    // host error: fall through, storage choice is not fatal
  }
  final env = Platform.environment;
  final dataHome =
      env['XDG_DATA_HOME'] ??
      (env['HOME'] != null ? '${env['HOME']}/.local/share' : null);
  if (dataHome != null) return Directory('$dataHome/unvisited');
  return Directory('.unvisited'); // a last-resort folder next to the app
}

/// Cache directory for storing offline map tiles.
/// Android: uses the app's cache directory.
/// Desktop (Linux dev runs): uses XDG cache home. Last resort: a local folder.
Future<Directory> _resolveCacheRoot() async {
  try {
    final path = await hostChannel.invokeMethod<String>('getCacheDir');
    if (path != null && path.isNotEmpty) {
      return Directory(path);
    }
  } on MissingPluginException {
    // no host implementation (desktop run): fall through to XDG below
  } on PlatformException {
    // host error: fall through, storage choice is not fatal
  }
  final env = Platform.environment;
  final cacheHome =
      env['XDG_CACHE_HOME'] ??
      (env['HOME'] != null ? '${env['HOME']}/.cache' : null);
  if (cacheHome != null) return Directory('$cacheHome/unvisited');
  return Directory('.unvisited_cache'); // a last-resort folder next to the app
}

/// Build time baked into the app by the Android build: gradle reads the
/// latest commit's time, which an installed app cannot do at runtime.
/// Desktop runs have no host implementation; the git probe covers them.
Future<String?> _resolveHostBuildTime() async {
  try {
    return await hostChannel.invokeMethod<String?>('getBuildTime');
  } on MissingPluginException {
    return null; // desktop run: no host implementation
  } on PlatformException {
    return null; // host error: fall through, the version tag is not fatal
  }
}

void _listenForSharedTracks(AppModel model) {
  sharedChannel.setMethodCallHandler((call) async {
    if (call.method == 'sharedTrack') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final path = args['path'] as String?;
      final name = args['name'] as String?;
      if (path != null) await model.importFromFile(path, name: name);
    }
  });
  // The channel only has a native side on Android; on desktop there is
  // nothing to listen for share intents, so a missing handler is expected.
  sharedChannel.invokeMethod('ready').catchError((_) {});
}

class UnvisitedApp extends StatelessWidget {
  const UnvisitedApp({
    super.key,
    required this.model,
    required this.cacheDir,
    this.versionFuture,
    this.locationSupported = false,
  });

  final AppModel model;
  final Directory cacheDir;
  final Future<String>? versionFuture;

  /// Whether the platform can deliver a position at all; see
  /// [locationSupportAvailable].
  final bool locationSupported;

  @override
  Widget build(BuildContext context) {
    // The language is a setting (Settings sheet), so the app root listens
    // to the model: changing it rebuilds MaterialApp with a new `locale`
    // and the whole tree re-resolves its strings. Null means "follow the
    // device".
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) => MaterialApp(
        title: 'Unvisited',
        locale: model.locale,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF4363D8),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF4363D8),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        themeMode: model.themeModeValue,
        // The app's own strings are looked up through AppStrings; the
        // delegate only makes MaterialApp resolve and expose the locale.
        // Material's built-in widget labels stay English (the app ships
        // without flutter_localizations), hence the _AnyLocale delegates:
        // Flutter's own Default* delegates only claim English, and a
        // supported locale they reject leaves the tree without
        // MaterialLocalizations - Scaffold's drawer and every Material
        // widget then fail to build.
        localizationsDelegates: const [
          _AnyLocaleMaterialDelegate(),
          _AnyLocaleWidgetsDelegate(),
          _AnyLocaleCupertinoDelegate(),
          _AppLocaleDelegate(),
        ],
        supportedLocales: AppStrings.supportedLocales,
        home: MapPage(
          model: model,
          cacheDir: cacheDir,
          versionFuture: versionFuture,
          locationSupported: locationSupported,
        ),
      ),
    );
  }
}

/// Exposes the resolved locale to the widget tree so `Localizations.localeOf`
/// (and therefore [AppStrings.ofContext]) returns the language the app
/// actually speaks, not the raw system locale.
///
/// A custom delegate instead of `flutter_localizations`' `GlobalMaterial-
/// Localizations`: the app's strings are its own (see AppStrings), and
/// pulling in the localization package for Material's built-in widget
/// labels would add a dependency for text the app never shows.
class _AppLocaleDelegate extends LocalizationsDelegate<AppStrings> {
  const _AppLocaleDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppStrings.supported.containsKey(locale.languageCode);

  @override
  Future<AppStrings> load(Locale locale) async => AppStrings.of(locale);

  @override
  bool shouldReload(_AppLocaleDelegate old) => false;
}

/// Material's built-in labels for *any* locale: Flutter's
/// `DefaultMaterialLocalizations.delegate` claims English only, and a
/// locale it rejects drops MaterialLocalizations from the tree entirely
/// (Scaffold's drawer asserts). English labels for the framework's own
/// widgets are the accepted trade-off for not depending on
/// flutter_localizations; the app's text comes from [AppStrings].
class _AnyLocaleMaterialDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _AnyLocaleMaterialDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      DefaultMaterialLocalizations.load(locale);

  @override
  bool shouldReload(_AnyLocaleMaterialDelegate old) => false;
}

/// Widgets counterpart of [_AnyLocaleMaterialDelegate].
class _AnyLocaleWidgetsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const _AnyLocaleWidgetsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      DefaultWidgetsLocalizations.load(locale);

  @override
  bool shouldReload(_AnyLocaleWidgetsDelegate old) => false;
}

/// Cupertino counterpart of [_AnyLocaleMaterialDelegate]: MaterialApp
/// appends Flutter's English-only Cupertino delegate itself, which would
/// otherwise warn (and leave CupertinoLocalizations missing) under a
/// non-English locale.
class _AnyLocaleCupertinoDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _AnyLocaleCupertinoDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      DefaultCupertinoLocalizations.load(locale);

  @override
  bool shouldReload(_AnyLocaleCupertinoDelegate old) => false;
}
