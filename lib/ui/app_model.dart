import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart' show Locale;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_strings.dart';
import '../road/road_bench.dart' show benchReport, runRoadBench;
import '../road/road_format.dart' show RoadFormatException;
import '../road/road_matcher.dart';
import '../road/road_store.dart';
import '../recording/position_source.dart' show PositionSource;
import '../recording/recording_session.dart' show RecordingSession;
import '../storage/track_store.dart';
import 'fog_of_war.dart' show unlockCenters;
import 'import_coordinator.dart';
import 'recording_controller.dart';
import 'recording_live.dart' show RecordingLiveState;

/// Why a position could not be obtained; each maps to a message that
/// tells the user what to do about it.
enum LocationFailure {
  /// No location plugin on this platform (desktop Linux, test runs).
  unavailable,

  /// Location services (GPS) are switched off system-wide.
  serviceDisabled,

  /// The user dismissed the permission prompt.
  permissionDenied,

  /// Permission was permanently refused; only system settings can undo it.
  permissionBlocked,
}

/// Outcome of a locate attempt: a position, or the reason there is none.
class LocateResult {
  const LocateResult.success(LatLng this.position) : failure = null;

  const LocateResult.failure(LocationFailure this.failure) : position = null;

  final LatLng? position;
  final LocationFailure? failure;
}

/// A track prepared for drawing on the map.
class MapTrack {
  const MapTrack({required this.meta, required this.points});

  final StoredTrack meta;
  final List<LatLng> points;
}

/// Why activating a picked road region file failed. The UI maps each to
/// a message in the caller's language.
enum RoadFileFailure {
  /// The file is not a road file at all (wrong magic, version or a
  /// corrupt directory).
  corrupt,

  /// The picked path is gone or unreadable by the time it is opened.
  missing,
}

/// UI state root: owns the store, the road region, the track catalog's
/// visibility and the settings, and exposes the two extracted concerns —
/// [imports] (every import path) and [recorder] (the recording session) —
/// as thin delegating members so the UI keeps one access point.
class AppModel extends ChangeNotifier {
  AppModel(this.store) {
    imports = ImportCoordinator(
      store: store,
      roadMatcher: () => _roadMatcher,
      onChanged: notifyListeners,
    );
    recorder = RecordingController(
      store: store,
      imports: imports,
      onChanged: notifyListeners,
    );
  }

  final TrackStore store;

  /// The import concern: every import path collapses onto one helper
  /// (store + roads + point-cache + summary choreography).
  late final ImportCoordinator imports;

  /// The recording concern: session lifecycle, staging, salvage, the
  /// per-fix repaint channel and the battery advisory.
  late final RecordingController recorder;

  /// The active road file, if any (user side-loaded; see
  /// `lib/road/road_format.dart`). Null means roads are not matched: the
  /// overlay is circles-only and unlock state stays empty.
  RoadStore? _roadStore;
  GeometricRoadMatcher? _roadMatcher;
  RoadStore? get roadStore => _roadStore;

  /// Activates a side-loaded road file for matching (null deactivates).
  ///
  /// Imports compute unlock state for new tracks while it is active.
  void setRoadFile(String? path) {
    // Release the previous file handle before swapping (the store reads
    // bucket slices from disk on demand).
    _roadStore?.close();
    if (path == null) {
      _roadStore = null;
      _roadMatcher = null;
    } else {
      final road = RoadStore.open(path);
      _roadStore = road;
      _roadMatcher = GeometricRoadMatcher(road);
      if (kProfileMode) _runRoadBench(path);
    }
    notifyListeners();
  }

  /// Profile-mode development benchmark: measures the road pipeline against
  /// the just-activated region file and prints the report to the console.
  /// Guarded by [kProfileMode], so debug and release builds never run it;
  /// the isolate keeps the region scan off the UI thread, and the bench
  /// opens its own store.
  void _runRoadBench(String path) {
    unawaited(() async {
      try {
        debugPrint(benchReport(await Isolate.run(() => runRoadBench(path))));
      } catch (e) {
        debugPrint('road bench failed: $e');
      }
    }());
  }

  /// The region file's display name as the settings sheet shows it, or
  /// null when none is set.
  String? get roadsName => store.roadsFile;

  List<StoredTrack> get tracks => store.tracks;

  Future<void> load() async {
    await store.load();
    _restoreRoadFile();
    // After the road file (if any) is active, so a salvaged recording
    // matches its corridors in the same pass.
    await recorder.salvageRecordings();
    notifyListeners();
  }

  /// Restores the road region recorded in the index. A file that is gone
  /// (or no longer a valid road file) falls back to circles-only: the
  /// setting is cleared so the app self-heals instead of failing every
  /// start, and previously recorded unlock state keeps rendering (it is
  /// stored in the catalog, not re-derived from the region file).
  void _restoreRoadFile() {
    final name = store.roadsFile;
    if (name == null) return;
    final path = store.roadFileFor(name);
    try {
      setRoadFile(path.path);
      return;
    } on RoadFormatException {
      // fall through: clear the stale reference below
    } on FileSystemException {
      // file deleted externally: fall through
    }
    setRoadFile(null);
    store.clearRoadsFile();
  }

  /// Opens the system file picker to choose a road region file (any file —
  /// the format, like track imports, is decided by content, never by
  /// extension) and activates it: the file is copied under the app root,
  /// the matcher swaps to it and every stored track is re-matched.
  /// Returns [RoadFileFailure] with the reason, or null on success or
  /// cancelled pick.
  Future<RoadFileFailure?> pickRoadFile() async {
    final picked = await FilePicker.pickFile();
    final path = picked?.path;
    if (path == null) return null; // cancelled
    return activateRoadFile(path);
  }

  /// Activates [pickedPath] as the road region (see [pickRoadFile]).
  Future<RoadFileFailure?> activateRoadFile(String pickedPath) async {
    // Validate before adopting: opening parses the header and the bucket
    // directory and rejects wrong magic, version and a corrupt directory.
    try {
      RoadStore.open(pickedPath).close();
    } on RoadFormatException {
      return RoadFileFailure.corrupt;
    } on FileSystemException {
      return RoadFileFailure.missing;
    }
    final storedPath = store.adoptRoadFile(pickedPath);
    notifyListeners();
    try {
      setRoadFile(storedPath);
      await _rematchAllTracks();
    } finally {
      notifyListeners();
    }
    return null;
  }

  /// Deactivates the road region and forgets its stored copy. Unlock
  /// state recorded on tracks survives: the corridors are materialized
  /// polylines in the catalog — exploration data, not cache.
  Future<void> removeRoadFile() async {
    await store.clearRoadsFile();
    setRoadFile(null);
  }

  /// Re-runs road matching for every stored track under the active region
  /// and merges the result into the persisted unlock state. Corridors are
  /// merged by OSM way id, never overwritten: a way an earlier region
  /// matched keeps its corridors (overlapping region files coalesce on
  /// the same way), so re-activating a region never duplicates and a swap
  /// adds what the stored tracks unlock under the new one.
  Future<void> _rematchAllTracks() async {
    final matcher = _roadMatcher;
    if (matcher == null) return;
    for (final t in store.tracks) {
      final data = store.loadPoints(t);
      if (data != null && data.points.isNotEmpty) {
        final match = matcher.match(
          unlockCenters(data.points.map((p) => LatLng(p.lat, p.lon))),
        );
        final merged = Map.of(t.unlockedWays);
        var changed = false;
        for (final entry in match.corridors.entries) {
          if (merged.containsKey(entry.key)) continue;
          merged[entry.key] = entry.value;
          changed = true;
        }
        if (changed) store.saveUnlockedWays(t, merged);
      }
      imports.invalidateCache(t.id);
      // Yield between tracks so a slow recompute repaints the busy
      // indicator instead of freezing the UI for the whole catalog.
      await Future<void>.delayed(Duration.zero);
    }
  }

  // --- Import concern, delegated to [imports] -----------------------------

  bool get busy => imports.busy;
  List<LatLng> get lastImportedPoints => imports.lastImportedPoints;
  int get importEpoch => imports.importEpoch;

  Future<void> importFromFile(String path, {String? name}) =>
      imports.importFromFile(path, name: name);

  Future<ImportSummary> importFromDirectory(String directoryPath) =>
      imports.importFromDirectory(directoryPath);

  Future<ImportSummary?> importViaDirectoryPicker() =>
      imports.importViaDirectoryPicker();

  Future<ImportSummary> importViaFilePicker() => imports.importViaFilePicker();

  // --- Recording concern, delegated to [recorder] --------------------------

  RecordingSession? get recording => recorder.recording;
  bool get isRecording => recorder.isRecording;
  RecordingLiveState get recordingLive => recorder.recordingLive;
  List<String> get salvagedRecordingNames => recorder.salvagedRecordingNames;
  void notifyRecordingFix() => recorder.notifyRecordingFix();
  Future<String?> startRecording(
          {PositionSource? source, bool permissionGate = true}) =>
      recorder.startRecording(source: source, permissionGate: permissionGate);
  Future<void> stopRecording({String? name}) =>
      recorder.stopRecording(name: name);
  void pauseRecording() => recorder.pauseRecording();
  void resumeRecording() => recorder.resumeRecording();
  String recordingName(DateTime start) => recorder.recordingName(start);
  Future<bool?> batteryOptimizationExcluded() =>
      recorder.batteryOptimizationExcluded();
  Future<bool?> requestPostNotifications() =>
      recorder.requestPostNotifications();
  Future<void> openBatteryOptimizationSettings() =>
      recorder.openBatteryOptimizationSettings();

  // --- Catalog -------------------------------------------------------------

  List<MapTrack> get visibleTracks {
    final out = <MapTrack>[];
    for (final t in store.tracks) {
      if (!t.visible) continue;
      var pts = imports.cachedPoints(t);
      if (pts == null) {
        final data = store.loadPoints(t);
        if (data == null) continue;
        pts = data.points.map((p) => LatLng(p.lat, p.lon)).toList();
        imports.rememberPoints(t, pts);
      }
      if (pts.isEmpty) continue;
      out.add(MapTrack(meta: t, points: pts));
    }
    return out;
  }

  Future<void> toggleVisible(StoredTrack t) async {
    await store.setVisible(t, !t.visible);
    notifyListeners();
  }

  /// True when every track is visible (an empty catalog counts as true).
  bool get allTracksVisible => store.tracks.every((t) => t.visible);

  /// Selects or deselects every track at once.
  Future<void> setAllVisible(bool visible) async {
    await store.setAllVisible(visible);
    notifyListeners();
  }

  Future<void> delete(StoredTrack t) async {
    await store.remove(t);
    imports.invalidateCache(t.id);
    notifyListeners();
  }

  /// Deletes every stored track (files and catalog entries).
  Future<void> deleteAll() async {
    await store.clearAll();
    imports.clearCache();
    notifyListeners();
  }

  /// The map's start center: the position saved by the previous run, or
  /// null when the app has never obtained a fix.
  LatLng? get savedPosition => store.lastPositionLat == null
      ? null
      : LatLng(store.lastPositionLat!, store.lastPositionLon!);

  // --- Settings ------------------------------------------------------------

  /// Exploration overlay tint key (see the tints in track_colors.dart),
  /// persisted in the index.
  String get trackTint => store.tint;

  /// Which screen edge the zoom slider hugs: 'left' or 'right'.
  String get zoomSliderSide => store.zoomSliderSide;

  /// Theme mode: 'system', 'light', or 'dark'.
  String get themeMode => store.themeMode;

  /// Base tile style: 'standard' (OSM raster) or 'cycle' (CyclOSM).
  String get tileLayer => store.tileLayer;

  /// Saves the exploration overlay tint; the map repaints via the usual
  /// notification.
  Future<void> setTrackTint(String key) async {
    await store.saveTint(key);
    notifyListeners();
  }

  Future<void> setZoomSliderSide(String side) async {
    await store.saveZoomSliderSide(side);
    notifyListeners();
  }

  /// Saves the theme mode; the app rebuilds via the usual notification.
  Future<void> setThemeMode(String mode) async {
    await store.saveThemeMode(mode);
    notifyListeners();
  }

  /// Saves the base tile style; the map refetches tiles via the usual
  /// notification.
  Future<void> setTileLayer(String layer) async {
    await store.saveTileLayer(layer);
    notifyListeners();
  }

  /// UI language choice: 'system' or a language code. The app rebuilds in
  /// the new language through the usual notification (MaterialApp watches
  /// the model for exactly this).
  String get language => store.language;

  /// The locale the UI should use, or null to follow the device. Unknown
  /// codes (hand-edited index, a language that was dropped) fall back to
  /// following the system rather than to a broken locale.
  Locale? get locale {
    final code = language;
    if (code == 'system') return null;
    return AppStrings.supported.containsKey(code) ? Locale(code) : null;
  }

  /// The ThemeMode the app should use. 'system' maps to ThemeMode.system,
  /// 'light' to ThemeMode.light, 'dark' to ThemeMode.dark.
  ThemeMode get themeModeValue => switch (themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  Future<void> setLanguage(String code) async {
    await store.saveLanguage(code);
    notifyListeners();
  }

  // --- Locate --------------------------------------------------------------

  /// The device's current position, or null when it cannot be obtained
  /// (permission denied, location services off, or no plugin). Use
  /// [locate] when the caller needs to tell the user *why* it failed.
  ///
  /// [prompt] decides whether the user may be asked for permission. The
  /// startup path must never prompt; the locate button prompts freely.
  Future<LatLng?> currentPosition({required bool prompt}) async {
    final result = await locate(prompt: prompt);
    return result.position;
  }

  /// Upper bound on a locate attempt; see [locate].
  static const _locateTimeout = Duration(seconds: 10);

  /// The device's current position together with the reason it is
  /// missing, so the UI can say what to fix instead of a generic
  /// "unavailable".
  ///
  /// [prompt] decides whether the user may be asked for permission. The
  /// startup path must never prompt; the locate button prompts freely.
  Future<LocateResult> locate({required bool prompt}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return const LocateResult.failure(LocationFailure.serviceDisabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (!prompt) {
          return const LocateResult.failure(LocationFailure.permissionDenied);
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocateResult.failure(LocationFailure.permissionBlocked);
      }
      if (permission == LocationPermission.denied) {
        return const LocateResult.failure(LocationFailure.permissionDenied);
      }
      // Bounded: without a time limit a cold fix can wait indefinitely,
      // and the UI (which shows a spinner meanwhile) would never settle.
      // Ten seconds is long enough for a cold GPS fix outdoors and short
      // enough not to feel stuck.
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: _locateTimeout,
        ),
      );
      final pos = LatLng(position.latitude, position.longitude);
      await store.savePosition(pos.latitude, pos.longitude);
      notifyListeners();
      return LocateResult.success(pos);
    } catch (_) {
      // No host implementation (desktop/test runs), a broken plugin
      // setup, or a decode error: degrade to "no location". Error and
      // Exception alike — the platform channel surfaces both.
      return const LocateResult.failure(LocationFailure.unavailable);
    }
  }

  /// All points of all visible tracks, for fitting the camera.
  List<LatLng> get allVisiblePoints =>
      visibleTracks.expand((t) => t.points).toList();

  @override
  void dispose() {
    recorder.recordingLive.dispose();
    super.dispose();
  }
}
