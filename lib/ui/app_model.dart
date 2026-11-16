import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../aggregate/aggregate_tracks.dart'
    show AggregateInput, AggregateTrack, AggregateIndex, UnionFindAggregateIndex;
import '../debug_log.dart';
import '../geo.dart' show haversineMeters;
import '../host_channel.dart' show hostChannel;
import '../l10n/app_strings.dart';
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
import 'track_colors.dart' show defaultTintKey, explorationTints;

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
    }
    notifyListeners();
  }

  /// The region file's display name as the settings sheet shows it, or
  /// null when none is set.
  String? get roadsName => store.roadsFile;

  List<StoredTrack> get tracks => store.tracks;

  Future<void> load() async {
    await store.load();
    DebugLog.instance.enabled = store.debugLogging;
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

  /// True while a heavy catalog operation is in flight: an import, or a
  /// visibility change that re-clusters and re-draws every track (see
  /// [setAllVisible]). MapPage shows the top progress indicator for it.
  bool get busy => imports.busy || _rebuilding;
  bool _rebuilding = false;
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
  Future<void> discardRecording() => recorder.discardRecording();
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

  /// Select-all with loading feedback (the drawer's select/deselect-all
  /// button): flags [busy] and waits one frame so the indicator paints
  /// *before* the rebuild, then applies the change via [setAllVisible]
  /// (whose rebuild frame re-parses and re-clusters every track), and
  /// clears the flag once that frame has painted.
  Future<void> setAllVisibleWithFeedback(bool visible) async {
    if (allTracksVisible == visible) return;
    _rebuilding = true;
    notifyListeners();
    await WidgetsBinding.instance.endOfFrame;
    await setAllVisible(visible);
    await WidgetsBinding.instance.endOfFrame;
    _rebuilding = false;
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

  // --- Export --------------------------------------------------------------

  /// The mime per stored format, matching the accept set the
  /// share-intent filter and the parser sniffing use.
  static const _trackMimes = <String, String>{
    'gpx': 'application/gpx+xml',
    'kmz': 'application/vnd.google-earth.kmz',
    'kml': 'application/vnd.google-earth.kml+xml',
    'tcx': 'application/xml',
    'fit': 'application/octet-stream',
  };

  static String _mimeFor(String format) =>
      _trackMimes[format.toLowerCase()] ?? 'application/octet-stream';

  /// Writes the track's original stored file as-is to a user-chosen path
  /// (records export as the GPX they were finalized into); returns the
  /// destination, or null when cancelled. Android shows the share sheet
  /// instead (the host channel's ACTION_SEND over the app-private file
  /// through the FileProvider) and returns null — there is no destination
  /// path to report. Throws on a failed export; the caller surfaces the
  /// error.
  Future<String?> exportTrack(StoredTrack track) async {
    if (Platform.isAndroid) {
      try {
        await hostChannel.invokeMethod('shareTrack', <String, Object?>{
          'path': store.trackFileFor(track).path,
          'mime': _mimeFor(track.format),
        });
      } on MissingPluginException {
        return null; // test runs, or a degraded build: nothing to do
      }
      return null;
    }
    final file = store.trackFileFor(track);
    // Sync read: tracks are small, and a synchronous read keeps the export
    // inside a widget test's fake-async zone (real-IO futures never
    // dispatch there — see the recording stop's runAsync note).
    final target = await FilePicker.saveFile(
      fileName: file.uri.pathSegments.last,
      bytes: file.readAsBytesSync(),
      mimeType: _mimeFor(track.format),
    );
    return target?.toFilePath();
  }

  /// The map's start center: the position saved by the previous run, or
  /// null when the app has never obtained a fix.
  LatLng? get savedPosition => store.lastPositionLat == null
      ? null
      : LatLng(store.lastPositionLat!, store.lastPositionLon!);

  // --- Settings ------------------------------------------------------------

  /// Exploration overlay tint key (see the tints in track_colors.dart),
  /// persisted in the index. The fog overlay colors by aggregate now; this
  /// drives the main fog aggregate's default and the swatch fallbacks.
  String get trackTint => store.tint;

  /// The live recording trace's tint key, persisted in the index.
  String get recordingTint => store.recordingTint;

  /// The resolved tint key per aggregate anchor: the per-aggregate
  /// override when one is set, else the palette rank — the earliest (the
  /// "main") aggregate keeps the app default, the others take the
  /// following palette colors in anchor-start order, cycling.
  Map<String, String> get aggregateTintKeys {
    final keys = <String, String>{};
    final ordered = [
      for (final a in aggregates)
        (anchor: a.anchorId, start: _anchorStart(a)),
    ]..sort((x, y) {
      final xs = x.start, ys = y.start;
      if (xs == null && ys == null) return x.anchor.compareTo(y.anchor);
      if (xs == null) return 1;
      if (ys == null) return -1;
      return xs.compareTo(ys);
    });
    final palette = explorationTints.keys.where((k) => k != defaultTintKey).toList();
    for (var i = 0; i < ordered.length; i++) {
      final anchor = ordered[i].anchor;
      keys[anchor] = i == 0
          ? store.aggregateColor(anchor) ?? defaultTintKey
          : store.aggregateColor(anchor) ?? palette[(i - 1) % palette.length];
    }
    return keys;
  }

  DateTime? _anchorStart(AggregateTrack a) => a.members
      .map((m) => m.startTimeUtc)
      .whereType<DateTime>()
      .fold<DateTime?>(null, (min, t) => min == null || t.isBefore(min) ? t : min);

  /// Which screen edge the zoom slider hugs: 'left' or 'right'.
  String get zoomSliderSide => store.zoomSliderSide;

  /// Theme mode: 'system', 'light', or 'dark'.
  String get themeMode => store.themeMode;

  /// Base tile style: 'standard' (OSM raster) or 'cycle' (CyclOSM).
  String get tileLayer => store.tileLayer;

  /// Whether the recording follow-camera rotates course-up: 'on' or
  /// 'off' (the default — the map stays north-up).
  String get mapRotation => store.mapRotation;

  /// Whether the screen stays on while recording (the default). The
  /// dashboard's model listener applies the latch on every change, so a
  /// toggle applies immediately, even mid-session.
  bool get keepScreenOn => store.keepScreenOn;

  /// Whether the in-app debug log accumulates (default off).
  bool get debugLogging => store.debugLogging;

  /// Saves the debug-logging switch and applies it to the log immediately.
  Future<void> setDebugLogging(bool on) async {
    await store.saveDebugLogging(on);
    DebugLog.instance.enabled = on;
    if (!on) DebugLog.instance.clear();
    DebugLog.instance.info('debug logging ${on ? 'enabled' : 'disabled'}');
    notifyListeners();
  }

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

  /// Saves whether the recording follow-camera rotates course-up
  /// ('on' or 'off').
  Future<void> setMapRotation(String rotation) async {
    await store.saveMapRotation(rotation);
    notifyListeners();
  }

  /// Saves whether the screen stays on while recording; the dashboard
  /// picks the change up through the usual notification.
  Future<void> setKeepScreenOn(bool on) async {
    await store.saveKeepScreenOn(on);
    notifyListeners();
  }

  /// Saves the live recording trace's tint (the fog overlay colors by
  /// aggregate now).
  Future<void> setRecordingTint(String key) async {
    await store.saveRecordingTint(key);
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

  /// A fix older than this is not a current position — while GPS works,
  /// fixes stream at ~1 Hz, so anything older is a stale cache entry from
  /// the fused provider, not where the user is now. Such a fix must not
  /// reveal the Record button or move the camera.
  static const Duration freshFixMaxAge = Duration(seconds: 30);

  /// The device's current position together with the reason it is
  /// missing, so the UI can say what to fix instead of a generic
  /// "unavailable".
  ///
  /// [prompt] decides whether the user may be asked for permission. The
  /// startup path must never prompt; the locate button prompts freely.
  Future<LocateResult> locate({required bool prompt}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        DebugLog.instance.warn('locate: location service disabled');
        return const LocateResult.failure(LocationFailure.serviceDisabled);
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (!prompt) {
          DebugLog.instance.info('locate: permission denied (silent)');
          return const LocateResult.failure(LocationFailure.permissionDenied);
        }
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        DebugLog.instance.warn('locate: permission blocked forever');
        return const LocateResult.failure(LocationFailure.permissionBlocked);
      }
      if (permission == LocationPermission.denied) {
        DebugLog.instance.warn('locate: permission denied after prompt');
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
      // The fused provider can hand back a stale cached fix; only a fresh
      // one counts as a position.
      final fixAge = DateTime.now().difference(position.timestamp);
      if (fixAge > freshFixMaxAge) {
        DebugLog.instance.warn(
          'locate: stale fix rejected (age ${fixAge.inSeconds}s)',
        );
        return const LocateResult.failure(LocationFailure.unavailable);
      }
      final pos = LatLng(position.latitude, position.longitude);
      DebugLog.instance.info(
        'locate: fix ${pos.latitude.toStringAsFixed(6)},${pos.longitude.toStringAsFixed(6)}'
        ' age=${fixAge.inMilliseconds}ms acc=${position.accuracy.toStringAsFixed(1)}',
      );
      await store.savePosition(pos.latitude, pos.longitude);
      notifyListeners();
      return LocateResult.success(pos);
    } catch (_) {
      // No host implementation (desktop/test runs), a broken plugin
      // setup, or a decode error: degrade to "no location". Error and
      // Exception alike — the platform channel surfaces both.
      DebugLog.instance.warn('locate: unavailable (exception)');
      return const LocateResult.failure(LocationFailure.unavailable);
    }
  }

  /// All points of all visible tracks, for fitting the camera.
  List<LatLng> get allVisiblePoints =>
      visibleTracks.expand((t) => t.points).toList();

  // --- Aggregates & selection ---------------------------------------------

  /// Clusters visible tracks into aggregates (points of different tracks
  /// within ~100 m — transitively — belong together). Recomputed lazily
  /// whenever the visible set changes; cached otherwise.
  static const AggregateIndex _aggregateIndex = UnionFindAggregateIndex();
  String? _aggregatesKey;
  List<AggregateTrack> _aggregates = const [];

  List<AggregateTrack> get aggregates {
    final visible = visibleTracks;
    final key = [for (final t in visible) t.meta.id].join('|');
    if (key != _aggregatesKey) {
      _aggregatesKey = key;
      _aggregates = _aggregateIndex.build([
        for (final t in visible)
          AggregateInput(
            id: t.meta.id,
            points: t.points,
            startTimeUtc: t.meta.startTimeUtc,
          ),
      ]);
    }
    return _aggregates;
  }

  /// The selected aggregate's anchor id (see [AggregateTrack.anchorId]),
  /// or null. Selection is by anchor so it survives the aggregates being
  /// recomputed as the visible set or the zoom changes.
  String? selectedAnchor;

  AggregateTrack? get selectedAggregate {
    final anchor = selectedAnchor;
    if (anchor == null) return null;
    for (final a in aggregates) {
      if (a.anchorId == anchor) return a;
    }
    // The aggregate is gone (hidden, deleted): drop the selection.
    selectedAnchor = null;
    return null;
  }

  /// Selects the aggregate with a point within [toleranceMeters] of
  /// [tap]; deselects when [clearIfMiss] and nothing matches. Returns
  /// whether a selection is active afterwards.
  bool selectAggregateAt(
    LatLng tap, {
    required double toleranceMeters,
    bool clearIfMiss = true,
  }) {
    for (final a in aggregates) {
      for (final p in a.points) {
        if (haversineMeters(tap.latitude, tap.longitude, p.latitude,
                p.longitude) <=
            toleranceMeters) {
          selectedAnchor = a.anchorId;
          notifyListeners();
          return true;
        }
      }
    }
    if (clearIfMiss && selectedAnchor != null) {
      selectedAnchor = null;
      notifyListeners();
    }
    return false;
  }

  /// Hides the selected aggregate's member tracks (deselect = the
  /// underlying tracks leave the map) and drops the selection.
  Future<void> hideSelectedAggregate() async {
    final selected = selectedAggregate;
    if (selected == null) return;
    selectedAnchor = null;
    for (final id in selected.trackIds) {
      final matches = store.tracks.where((s) => s.id == id);
      final t = matches.isEmpty ? null : matches.first;
      if (t != null && t.visible) await store.setVisible(t, false);
    }
    notifyListeners();
  }

  /// The selected aggregate's color override key, or null for the palette
  /// rank default. Persisted under the aggregate's anchor id, so it
  /// survives membership changes.
  String? get selectedAggregateColor =>
      selectedAnchor == null ? null : store.aggregateColor(selectedAnchor!);

  /// Saves (an empty [tintKey] clears) the selected aggregate's color
  /// override, keyed by its anchor.
  Future<void> setAggregateColor(String tintKey) async {
    final anchor = selectedAnchor;
    if (anchor == null) return;
    await store.saveAggregateColor(anchor, tintKey);
    notifyListeners();
  }

  /// The resolved tint key of the aggregate a track belongs to (what the
  /// map draws), or the default when the track is hidden — it leaves no
  /// aggregate until re-shown. The track list's color dot reads this.
  String tintKeyForTrack(StoredTrack t) {
    if (!t.visible) return defaultTintKey;
    for (final a in aggregates) {
      if (a.trackIds.contains(t.id)) {
        return aggregateTintKeys[a.anchorId] ?? defaultTintKey;
      }
    }
    return defaultTintKey;
  }

  /// Bumped whenever a fit-to-aggregate request fires; MapPage compares
  /// against the value it last handled (the importEpoch pattern).
  int fitRequestEpoch = 0;

  /// Selects the aggregate the track belongs to and requests a camera fit
  /// to its points (the selection bar appears with it). No-op with no
  /// aggregate (a hidden track has none until it is re-shown).
  void selectAndFitAggregate(StoredTrack t) {
    if (!t.visible) return;
    for (final a in aggregates) {
      if (a.trackIds.contains(t.id)) {
        selectedAnchor = a.anchorId;
        fitRequestEpoch++;
        notifyListeners();
        return;
      }
    }
  }

  @override
  void dispose() {
    recorder.recordingLive.dispose();
    super.dispose();
  }
}
