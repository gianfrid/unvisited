import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../host_channel.dart';
import '../l10n/app_strings.dart';
import '../models/track.dart' show TrackData;
import '../road/road_bench.dart' show benchReport, runRoadBench;
import '../road/road_format.dart' show RoadFormatException;
import '../road/road_matcher.dart';
import '../road/road_store.dart';
import '../storage/track_store.dart';
import '../recording/position_source.dart' show PositionSource;
import '../recording/android_position_source.dart'
    show AndroidPositionSource;
import '../recording/recording_session.dart';
import '../recording/staging_gpx.dart'
    show FileStageSink, GpxStageWriter, salvageGpx;
import 'fog_of_war.dart' show unlockCenters;

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

class ImportSummary {
  ImportSummary() : imported = 0, duplicates = 0, skipped = 0, failed = 0;

  int imported;
  int duplicates;
  int skipped;
  int failed;

  void add(ImportResult r) {
    switch (r.reason) {
      case 'duplicate':
        duplicates++;
      case null:
        imported++;
      default:
        if (r.reason!.startsWith('skipped:')) {
          skipped++;
        } else {
          failed++;
        }
    }
  }

  bool get isEmpty => imported + duplicates + skipped + failed == 0;

  /// The summary as one line of user-facing text. The strings come from
  /// the caller's locale: this class is UI state, not a place to bake in
  /// English.
  String describe(AppStrings strings) {
    final parts = <String>[
      if (imported > 0) strings.importedCount(imported),
      if (duplicates > 0) strings.duplicateCount(duplicates),
      if (skipped > 0) strings.skippedCount(skipped),
      if (failed > 0) strings.failedCount(failed),
    ];
    return parts.isEmpty ? strings.nothingToImport : parts.join(', ');
  }
}

/// UI state root: owns the store, caches each visible track's points for
/// the fog-of-war overlay, exposes actions.
class AppModel extends ChangeNotifier {
  AppModel(this.store);

  final TrackStore store;
  final _pointCache = <String, List<LatLng>>{};

  /// The active road file, if any (user side-loaded; see
  /// `lib/road/road_format.dart`). Null means roads are not matched: the
  /// overlay is circles-only and unlock state stays empty.
  RoadStore? _roadStore;
  GeometricRoadMatcher? _roadMatcher;
  RoadStore? get roadStore => _roadStore;

  /// Activates a side-loaded road file for matching (null deactivates).
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
  /// the just-activated region file (TODO "profiling follow-ups") and prints
  /// the report to the console. Guarded by [kProfileMode], so debug and
  /// release builds never run it; the isolate keeps the region scan off the
  /// UI thread, and the bench opens its own store.
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

  bool _busy = false;
  bool get busy => _busy;

  /// Points of the tracks added by the most recent import operation, so the
  /// map can refit its camera on what was just imported. [importEpoch] is
  /// bumped on every change; readers compare it against the epoch they last
  /// handled.
  List<LatLng> lastImportedPoints = const [];
  int importEpoch = 0;

  void _noteImported(List<LatLng> out, ImportResult result) {
    final data = result.data;
    if (!result.imported || data == null || data.isEmpty) return;
    out.addAll(data.points.map((p) => LatLng(p.lat, p.lon)));
  }

  Future<void> load() async {
    await store.load();
    _restoreRoadFile();
    // After the road file (if any) is active, so a salvaged recording
    // matches its corridors in the same pass.
    await _salvageRecordings();
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

  /// Reads a picked file (or share-intent temp file) through the pipeline.
  Future<void> importFromFile(String path, {String? name}) async {
    final newPoints = <LatLng>[];
    _busy = true;
    notifyListeners();
    try {
      final f = File(path);
      final result = store.importBytes(
        f.readAsBytesSync(),
        filename: name ?? path,
      );
      _noteImported(newPoints, result);
      _matchRoads(result);
      if (result.imported) _pointCache.remove(result.track!.id);
      notifyListeners();
    } finally {
      _recordNewImports(newPoints);
      _busy = false;
      notifyListeners();
    }
  }

  void _recordNewImports(List<LatLng> newPoints) {
    if (newPoints.isEmpty) return;
    lastImportedPoints = newPoints;
    importEpoch++;
  }

  /// Computes road unlock state for a freshly imported track and persists
  /// it on the catalog entry. No-op without an active road file — the
  /// overlay stays circles-only and the index field stays absent. Matching
  /// runs on the same cell-coalesced unlock centers the circles use, so
  /// roads and circles always tell the same story.
  void _matchRoads(ImportResult result) {
    final matcher = _roadMatcher;
    final data = result.data;
    if (!result.imported || matcher == null || data == null) return;
    _matchTrack(result.track!, data);
  }

  /// Computes and persists one track's unlock state under the active
  /// matcher (the caller guarantees one is set).
  void _matchTrack(StoredTrack track, TrackData data) {
    final match = _roadMatcher!.match(
      unlockCenters(data.points.map((p) => LatLng(p.lat, p.lon))),
    );
    if (match.corridors.isNotEmpty) {
      store.saveUnlockedWays(track, match.corridors);
    }
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
    _busy = true;
    notifyListeners();
    try {
      setRoadFile(storedPath);
      await _rematchAllTracks();
    } finally {
      _busy = false;
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
      _pointCache.remove(t.id);
      // Yield between tracks so a slow recompute repaints the busy
      // indicator instead of freezing the UI for the whole catalog.
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Runs one candidate file through the unified pipeline, recording it in
  /// [summary] and collecting its points for the camera refit.
  void _importBytes(
    List<int> bytes,
    String name,
    ImportSummary summary,
    List<LatLng> newPoints,
  ) {
    final result = store.importBytes(bytes, filename: name);
    _noteImported(newPoints, result);
    _matchRoads(result);
    summary.add(result);
  }

  /// Recursively imports every supported track file below [directoryPath]
  /// (platform-picker folder on desktop, where directories are real paths).
  Future<ImportSummary> importFromDirectory(String directoryPath) async {
    final summary = ImportSummary();
    final newPoints = <LatLng>[];
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return summary;
    await for (final entry in dir.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final ext = name.toLowerCase().split('.').last;
      if (!const {'gpx', 'fit', 'kmz', 'kml', 'tcx'}.contains(ext)) {
        continue;
      }
      try {
        _importBytes(entry.readAsBytesSync(), name, summary, newPoints);
      } on Exception {
        summary.failed++;
      }
    }
    _pointCache.clear();
    _recordNewImports(newPoints);
    notifyListeners();
    return summary;
  }

  /// Opens the SAF folder picker and imports every supported file below the
  /// chosen folder (Android), or opens the platform directory picker
  /// (desktop, where the host channel is missing and picked folders are real
  /// paths dart:io can walk). Returns null when the user cancelled.
  Future<ImportSummary?> importViaDirectoryPicker() async {
    final String? treeUri;
    try {
      treeUri = await hostChannel.invokeMethod<String>('pickDirectory');
    } on MissingPluginException {
      // Desktop run: no host-side implementation, fall through to
      // file_picker's platform portal directory picker.
      final dir = await FilePicker.getDirectoryPath();
      if (dir == null) return null;
      return importFromDirectory(dir);
    }
    if (treeUri == null) return null; // user cancelled
    return _importSafTree(treeUri);
  }

  /// Android SAF folder import. The system tree picker grants access to a
  /// content:// tree URI — no storage permission can grant raw-path access
  /// to it (scoped storage killed that on Android 13+, and USB-OTG providers
  /// never had real paths). The host channel scans the tree and copies the
  /// supported files into a staging directory; the unified pipeline consumes
  /// those bytes and the staged copies are deleted again.
  Future<ImportSummary> _importSafTree(String treeUri) async {
    final summary = ImportSummary();
    final newPoints = <LatLng>[];
    _busy = true;
    notifyListeners();
    try {
      final staged =
          await hostChannel.invokeListMethod<Map<Object?, Object?>>(
            'listTrackFiles',
            treeUri,
          ) ??
          const <Map<Object?, Object?>>[];
      for (final entry in staged) {
        final path = entry['path'] as String?;
        final name = entry['name'] as String?;
        if (path == null || name == null) continue;
        final file = File(path);
        try {
          _importBytes(file.readAsBytesSync(), name, summary, newPoints);
        } on Exception {
          summary.failed++;
        } finally {
          try {
            file.deleteSync();
          } on Exception {
            // Staging lives in the app cache dir; a leftover is harmless.
          }
        }
      }
    } finally {
      _pointCache.clear();
      _recordNewImports(newPoints);
      _busy = false;
      notifyListeners();
    }
    return summary;
  }

  /// Opens the system file picker and imports the chosen files.
  Future<ImportSummary> importViaFilePicker() async {
    final summary = ImportSummary();
    final newPoints = <LatLng>[];
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gpx', 'fit', 'kmz', 'kml', 'tcx'],
    );
    for (final pf in picked) {
      final path = pf.path;
      if (path == null) continue;
      try {
        _importBytes(File(path).readAsBytesSync(), pf.name, summary, newPoints);
      } on Exception {
        summary.failed++;
      }
    }
    _pointCache.clear();
    _recordNewImports(newPoints);
    notifyListeners();
    return summary;
  }

  List<MapTrack> get visibleTracks {
    final out = <MapTrack>[];
    for (final t in store.tracks) {
      if (!t.visible) continue;
      var pts = _pointCache[t.id];
      if (pts == null) {
        final data = store.loadPoints(t);
        if (data == null) continue;
        pts = data.points.map((p) => LatLng(p.lat, p.lon)).toList();
        _pointCache[t.id] = pts;
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
    _pointCache.remove(t.id);
    notifyListeners();
  }

  /// Deletes every stored track (files and catalog entries).
  Future<void> deleteAll() async {
    await store.clearAll();
    _pointCache.clear();
    notifyListeners();
  }

  /// The map's start center: the position saved by the previous run, or
  /// null when the app has never obtained a fix.
  LatLng? get savedPosition => store.lastPositionLat == null
      ? null
      : LatLng(store.lastPositionLat!, store.lastPositionLon!);

  /// The live recording session, or null. The map's HUD chip reads this.
  RecordingSession? _recording;
  RecordingSession? get recording => _recording;

  /// The file the live session stages its fixes into, or null.
  File? _recordingFile;
  bool get isRecording => _recording != null;

  /// Repaints the UI for one delivered recording fix: the dashboard's
  /// live stats and the follow-camera marker rebuild off the session's
  /// intake, whose 1 Hz fixes are the tick they need. Wraps the protected
  /// notification so listeners outside the model's own members stay legal.
  void notifyRecordingFix() => notifyListeners();

  /// Starts recording: the while-in-use permission is requested up front
  /// (same flow as the locate attempt — a session is never started from
  /// the background), the engine consumes the Android source, and fixes
  /// stage into `<app root>/recording/<start timestamp>.gpx` as they
  /// arrive. Returns the staged file's name, or null when the
  /// user declined (or no host plugin answers — widget tests run here);
  /// desktop runs never get here, the Record action stays hidden where
  /// the platform has no location support. Spec rule: desktop recording
  /// is backlog, Linux ships no location source at all.
  Future<String?> startRecording(
      {PositionSource? source, bool permissionGate = true}) async {
    if (_recording != null) return null; // One at a time.
    if (permissionGate) {
      try {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return null;
        }
      } catch (_) {
        // No host plugin (widget tests, a broken setup): the gate fails
        // closed instead of half-starting a session nobody can feed.
        return null;
      }
    }
    final start = DateTime.now();
    final recordingDir = Directory(
        '${store.root.path}${Platform.pathSeparator}recording');
    recordingDir.createSync(recursive: true);
    final file = File(
        '${recordingDir.path}${Platform.pathSeparator}'
        '${start.millisecondsSinceEpoch}.gpx');
    final sink = FileStageSink(file);
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: _recordingName(start)),
      // The dashboard's tick: every delivered fix, after the engine
      // processed it, repaints the HUD and moves the follow-camera.
      onFix: (_) => notifyRecordingFix(),
    );
    _recording = session;
    _recordingFile = file;
    session.start(source ?? const AndroidPositionSource());
    notifyListeners();
    return file.uri.pathSegments.last;
  }

  /// Stops recording: the finalized GPX goes through the unified import
  /// pipeline like any other source (dedup, fog, road corridors all
  /// behave identically for a recorded track), and the staged file is
  /// deleted — the catalog owns the copy under `tracks/`. A killed
  /// process never gets here: its un-finalized file stays behind, and
  /// the startup salvage imports the partial track.
  Future<void> stopRecording() async {
    final session = _recording;
    final file = _recordingFile;
    if (session == null || file == null) return;
    _recording = null;
    _recordingFile = null;
    notifyListeners(); // The chip is gone while the import still runs.
    await session.stop();
    final bytes = await file.readAsBytes();
    if (bytes.isNotEmpty) {
      _importRecordingBytes(bytes, session.stage.trackName);
    }
    // The staged file is spent; the catalog's copy is the one that stays.
    if (file.existsSync()) file.deleteSync();
  }

  /// Pauses the live session: the current `<trkseg>` closes, the paused
  /// stretch changes neither distance nor moving time, and the resume —
  /// the next accepted fix — opens a new segment. No-op when no session
  /// runs or none is paused.
  void pauseRecording() {
    final session = _recording;
    if (session == null) return;
    session.pause();
    notifyListeners();
  }

  /// Resumes a paused session (see [pauseRecording]): the next accepted
  /// fix opens a new `<trkseg>`. No-op when no session runs or none is
  /// paused.
  void resumeRecording() {
    final session = _recording;
    if (session == null || session.state != RecordingState.paused) return;
    session.resume();
    notifyListeners();
  }

  /// Un-finalized (or un-imported) recordings found and imported at
  /// startup — the staged files of killed sessions. The UI announces
  /// these once; the names are the catalog names the GPX carries, so
  /// sentence-building stays with the strings.
  final List<String> salvagedRecordingNames = [];

  /// Imports every staged recording left over under `recording/`: a
  /// kill between finalize and the catalog import leaves a complete
  /// file, which imports as-is; a kill mid-session leaves one missing
  /// the closers, which salvage repairs first; a kill before the first
  /// flushed point leaves nothing usable, which is junk and is removed.
  /// Unreadable files stay put — unknown bytes are not destroyed on a
  /// guess, they surface again next start.
  Future<void> _salvageRecordings() async {
    final dir = Directory(
        '${store.root.path}${Platform.pathSeparator}recording');
    if (!dir.existsSync()) return;
    for (final entry in dir.listSync()) {
      if (entry is! File || !entry.path.endsWith('.gpx')) continue;
      String text;
      try {
        text = await entry.readAsString();
      } on Exception {
        continue; // unreadable: leave it for a later run
      }
      final gpx = text.contains('</gpx>') ? text : salvageGpx(text);
      if (gpx == null) {
        // Nothing was ever staged (header only): junk, removed.
        entry.deleteSync();
        continue;
      }
      final result =
          _importRecordingBytes(gpx.codeUnits, entry.uri.pathSegments.last);
      entry.deleteSync();
      if (result.imported) {
        salvagedRecordingNames.add(result.track!.name);
        notifyListeners();
      }
    }
  }

  /// Imports finalized recording bytes (a deliberate stop, or a salvage)
  /// through the unified pipeline: a recorded track is an ordinary
  /// catalog track — dedup, fog and road corridors all apply — and the
  /// point cache is invalidated so the overlay picks the points up.
  ImportResult _importRecordingBytes(List<int> bytes, String filename) {
    final result = store.importBytes(bytes, filename: filename);
    if (result.imported) _pointCache.remove(result.track!.id);
    _matchRoads(result);
    notifyListeners();
    return result;
  }

  /// Whether Android's battery manager exempts the app — the risk the
  /// recording robustness note in Settings is about (OEM battery managers
  /// kill foreground services regardless of the OS's own). Null when the
  /// platform cannot say (no host plugin; desktop runs, tests).
  Future<bool?> batteryOptimizationExcluded() async {
    try {
      return await hostChannel
          .invokeMethod<bool>('batteryOptimizationExcluded');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The soft POST_NOTIFICATIONS ask (API 33+): one non-blocking dialog,
  /// fired from the Record tap, whose grant result decides only whether
  /// the recording foreground service's notification is shown — a
  /// refusal leaves the session mute, never stopped. Null when the
  /// platform cannot say (no host plugin; desktop runs, tests).
  Future<bool?> requestPostNotifications() async {
    try {
      return await hostChannel.invokeMethod<bool>('requestPostNotifications');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens Android's battery-optimization settings screen: the advisory's
  /// soft tap-through. Never an automated exemption request (the intent
  /// Play flags; see the recording research report).
  Future<void> openBatteryOptimizationSettings() async {    try {
      await hostChannel.invokeMethod('openBatteryOptimizationSettings');
    } on MissingPluginException {
      // No host plugin: nothing to open.
    } on PlatformException {
      // The settings screen is unavailable: nothing to open.
    }
  }

  /// A staged track's name inside the GPX: the UTC start's numerals, so a
  /// recorded track reads by when it was taken (locale-independent — model
  /// classes never build sentences).
  String _recordingName(DateTime start) =>
      '${start.year.toString().padLeft(4, '0')}-'
      '${start.month.toString().padLeft(2, '0')}-'
      '${start.day.toString().padLeft(2, '0')} '
      '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';


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
}
