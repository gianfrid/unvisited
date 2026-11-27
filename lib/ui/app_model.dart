import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../aggregate/aggregate_tracks.dart'
    show AggregateInput, AggregateTrack, AggregateIndex, UnionFindAggregateIndex;
import '../aggregate/member_colors.dart'
    show MemberColorAssignment, assignMemberColors;
import '../debug_log.dart';
import '../geo.dart' show haversineMeters;
import '../host_channel.dart' show hostChannel;
import '../l10n/app_strings.dart';
import '../playback/track_playback.dart' show TrackPlayback;
import '../photos/image_picker_source.dart';
import '../photos/photo_export.dart';
import '../photos/photo_source.dart';
import '../road/road_format.dart' show RoadFormatException;
import '../road/road_coverage.dart';
import '../road/road_matcher.dart';
import '../road/road_store.dart';
import '../recording/position_source.dart' show PositionSource;
import '../recording/recording_session.dart' show RecordingSession;
import '../storage/track_store.dart';
import 'fog_of_war.dart' show fogStyleOrDefault, unlockCenters;
import 'import_coordinator.dart';
import 'playback_controller.dart';
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

/// Result of a camera press, as the UI needs it: the saved entry, or
/// which kind of nothing happened — the two read differently to the user
/// (a deliberate back-out is not an error).
sealed class PhotoAddResult {
  const PhotoAddResult();
}

/// The photo is cataloged at the captured position.
final class PhotoAdded extends PhotoAddResult {
  const PhotoAdded(this.photo);

  final StoredPhoto photo;
}

/// The user backed out of the camera app: nothing changed, nothing to
/// report as a failure.
final class PhotoAddDeclined extends PhotoAddResult {
  const PhotoAddDeclined();
}

/// The capture could not complete (platform error, unreadable result).
final class PhotoAddFailed extends PhotoAddResult {
  const PhotoAddFailed();
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
  AppModel(this.store, {PhotoSource? photoSource})
      : photoSource = photoSource ?? defaultPhotoSource() {
    imports = ImportCoordinator(
      store: store,
      roadMatcher: () => _roadMatcher,
      onChanged: _catalogDataChanged,
    );
    recorder = RecordingController(
      store: store,
      imports: imports,
      onChanged: _catalogDataChanged,
    );
    player = PlaybackController(store: store, onChanged: notifyListeners);
  }

  final TrackStore store;

  /// The camera-capture seam (`lib/photos/photo_source.dart`): injected
  /// so tests feed captures fakes; defaults to image_picker on Android
  /// and a graceful failure everywhere else — only the Android camera
  /// button can call it.
  final PhotoSource photoSource;

  /// The import concern: every import path collapses onto one helper
  /// (store + roads + point-cache + summary choreography).
  late final ImportCoordinator imports;

  /// The recording concern: session lifecycle, staging, salvage, the
  /// per-fix repaint channel and the battery advisory.
  late final RecordingController recorder;

  /// The playback concern: the replay of one stored track and its
  /// per-tick repaint channel. Structural changes (start/stop) notify
  /// the model — they mount and unmount map layers; per-tick repaints
  /// stay on `player.playbackLive`.
  late final PlaybackController player;

  /// The active road file, if any (user side-loaded; see
  /// `lib/road/road_format.dart`). Null means roads are not matched: the
  /// overlay is circles-only and unlock state stays empty.
  RoadStore? _roadStore;
  GeometricRoadMatcher? _roadMatcher;
  ViewportCoverage? _viewportCoverage;
  RoadStore? get roadStore => _roadStore;

  /// The viewport chip's last answer, or null when there is nothing to
  /// show: no region, the unvisited-roads setting is off, below the zoom
  /// floor, or no roads in view.
  CoverageReport? _viewportReport;
  CoverageReport? get viewportReport => _viewportReport;

  /// The unvisited-roads overlay for the settled viewport: one entry
  /// per viewport way with unmatched stretches, empty when the overlay
  /// floor says no (the chip may still answer at wider views).
  List<OverlayWay> _viewportOverlay = const [];
  List<OverlayWay> get viewportOverlay => _viewportOverlay;

  /// Catalog or unlock state changed: any memoized coverage report is
  /// stale at an unchanged viewport too, so it is dropped and the still-
  /// settled viewport recomputed before the UI repaints.
  void _catalogDataChanged() {
    _viewportCoverage?.invalidate();
    if (_viewportCorners != null) _recomputeViewportCoverage();
    notifyListeners();
  }

  /// The camera settled on a new viewport (or the map finished a
  /// programmatic move): recompute the unvisited share once the camera
  /// has been still for a moment, so a pan or zoom burst pays one pass.
  /// The camera settled on a new viewport: recompute the unvisited
  /// share for it now. The map page owns the settle-debounce (a view
  /// concern); this is what its timer fires. The pass is asynchronous
  /// and lands the result, or null, with one notifyListeners.
  void viewportSettled(LatLng southWest, LatLng northEast) {
    _viewportCorners = (southWest, northEast);
    _recomputeViewportCoverage();
  }

  (LatLng, LatLng)? _viewportCorners;

  Future<void> _recomputeViewportCoverage() async {
    final coverage = _viewportCoverage;
    final corners = _viewportCorners;
    // The setting is the feature switch: off means no report, no
    // overlay, and no geometry pass at all. Clearing here (not just
    // hiding the chip) keeps a stale answer from outliving the toggle
    // and stops the pass from decoding buckets for nothing.
    if (coverage == null || corners == null || !showUnvisitedRoads) {
      var changed = false;
      if (_viewportReport != null) {
        _viewportReport = null;
        changed = true;
      }
      if (_viewportOverlay.isNotEmpty) {
        _viewportOverlay = const [];
        changed = true;
      }
      if (changed) notifyListeners();
      return;
    }
    final corridors = mergedCorridors();
    final report =
        await coverage.coverage(corners.$1, corners.$2, corridors);
    // A later settle, or switching the feature off, superseded this
    // pass while it awaited: its answer would arrive out of order (and
    // must not re-populate a switched-off chip).
    if (_viewportCorners != corners || !showUnvisitedRoads) return;
    final overlay =
        await coverage.unvisitedIn(corners.$1, corners.$2, corridors);
    if (_viewportCorners != corners || !showUnvisitedRoads) return;
    final changed = !identical(report, _viewportReport) ||
        !identical(overlay, _viewportOverlay);
    _viewportReport = report;
    _viewportOverlay = overlay;
    if (changed) notifyListeners();
  }

  /// All *visible* tracks' unlock corridors merged by way id - the
  /// coverage input. Visible only on purpose: the corridor layer also
  /// draws visible tracks only, so hiding a track must return its
  /// roads to the unvisited overlay (and to the chip's share) rather
  /// than leave grey roads the chip still counts as walked. Matching
  /// and persistence stay unconditional; visibility is presentation.
  /// Corridors from other regions' way ids simply do not intersect the
  /// active store's buckets and contribute nothing.
  Map<String, List<List<LatLng>>> mergedCorridors() {
    final merged = <String, List<List<LatLng>>>{};
    for (final t in store.tracks) {
      if (!t.visible) continue;
      t.unlockedWays.forEach((wayId, corridors) {
        merged.putIfAbsent(wayId, () => []).addAll(corridors);
      });
    }
    return merged;
  }

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
      _viewportCoverage = null;
    } else {
      final road = RoadStore.open(path);
      _roadStore = road;
      _roadMatcher = GeometricRoadMatcher(road);
      _viewportCoverage = ViewportCoverage(road);
    }
    _viewportReport = null;
    _viewportOverlay = const [];
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
    // The camera has not moved, but the answer changed with the region
    // and the rematch: recompute the still-settled viewport right away
    // instead of waiting for the next camera settle.
    if (_viewportCorners != null) _recomputeViewportCoverage();
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
        if (changed) {
          store.saveUnlockedWays(t, merged);
          // Freshly matched corridors change the unvisited share even at
          // an unchanged viewport.
          _viewportCoverage?.invalidate();
        }
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
          {PositionSource? source, bool permissionGate = true}) async {
    // A session and a replay would fight over the one follow-camera;
    // the menu gates starting a replay during a session, this rules
    // the reverse — the live session wins, the replay yields.
    player.stop();
    return recorder.startRecording(source: source, permissionGate: permissionGate);
  }
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

  // --- Playback concern, delegated to [player] --------------------------

  /// The running track replay, or null (the map's layers and bar read
  /// this).
  TrackPlayback? get playback => player.playback;

  /// Starts replaying [track] (the track list's ⋮ menu — the menu
  /// disables the entry for tracks without a walkable timeline, no
  /// recording session and existing tracks only). Returns whether a
  /// replay started.
  bool startPlayback(StoredTrack track) => player.start(track);

  /// Stops the replay (the playback bar's close button). Also resets the
  /// map rotation to north-up: with nothing moving anymore the course
  /// arrow would linger selected for no function.
  Future<void> stopPlayback() async {
    player.stop();
    await setMapRotation('north');
  }

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
    _catalogDataChanged();
  }

  /// True when every track is visible (an empty catalog counts as true).
  bool get allTracksVisible => store.tracks.every((t) => t.visible);

  /// Selects or deselects every track at once.
  Future<void> setAllVisible(bool visible) async {
    await store.setAllVisible(visible);
    _catalogDataChanged();
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
    // A deleted track's replay stops with it — a marker replaying a
    // track that no longer exists would be a ghost of deleted data.
    player.trackRemoved(t.id);
    notifyListeners();
  }

  /// Deletes every stored track (files and catalog entries).
  Future<void> deleteAll() async {
    await store.clearAll();
    imports.clearCache();
    // Every track is gone, the played one included.
    player.stop();
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

  /// The whole catalog (index + track files) as one zip, ready to save.
  Uint8List exportCatalogBytes() => store.exportCatalogBytes();

  /// Re-imports an export zip through the unified pipeline; returns how
  /// many tracks were newly added (content-hash dedup applies). Throws
  /// [FormatException] when the zip is not an Unvisited export.
  int importCatalogBytes(List<int> bytes) {
    final added = store.importCatalogBytes(bytes);
    notifyListeners();
    return added;
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

  /// Which screen edge the control pill hugs: 'left' or 'right'.
  String get zoomSliderSide => store.zoomSliderSide;

  /// Theme mode: 'system', 'light', or 'dark'.
  String get themeMode => store.themeMode;

  /// Base tile style: 'standard' (OSM raster) or 'cycle' (CyclOSM).
  String get tileLayer => store.tileLayer;

  /// The recording follow-camera's rotation mode: 'north' (the default —
  /// the map stays north-up) or 'course' (course-up, where below the
  /// low-speed gate the compass takes over the rotation).
  String get mapRotation => store.mapRotation;

  /// The rotation modes in the order the control pill's button cycles
  /// through them.
  static const rotationModes = <String>['north', 'course'];

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

  /// Saves the recording follow-camera's rotation mode — one of
  /// [rotationModes].
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

  /// Whether the unvisited-roads presentation draws: the dashed
  /// overlay and the coverage chip together. Turning it back on
  /// recomputes the still-settled viewport — a static camera never
  /// settles again on its own, and neither the layer nor the chip must
  /// wait for the next pan.
  bool get showUnvisitedRoads => store.showUnvisitedRoads;

  /// Whether the geotagged-photos feature is on (the Settings switch):
  /// gates the camera button and the map pins. Stored photos are kept
  /// either way.
  bool get photosEnabled => store.photosEnabled;

  Future<void> setPhotosEnabled(bool value) async {
    if (value == photosEnabled) return;
    await store.savePhotosEnabled(value);
    notifyListeners();
  }

  Future<void> setShowUnvisitedRoads(bool value) async {
    if (value == showUnvisitedRoads) return;
    await store.saveShowUnvisitedRoads(value);
    // Either way the visible answer changes: off clears the report and
    // the dashed layer immediately, on restores both — a static camera
    // never settles again on its own.
    if (_viewportCorners != null) _recomputeViewportCoverage();
    notifyListeners();
  }

  /// Saves the live recording trace's tint (the fog overlay colors by
  /// aggregate now).
  Future<void> setRecordingTint(String key) async {
    await store.saveRecordingTint(key);
    notifyListeners();
  }

  /// The exploration overlay's display style ('circles', 'polyline' or
  /// 'ink'), normalized through fogStyleOrDefault.
  String get fogStyle => fogStyleOrDefault(store.fogStyle);

  /// Saves the exploration overlay's display style.
  Future<void> setFogStyle(String style) async {
    await store.saveFogStyle(style);
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

  // --- Photos -------------------------------------------------------------

  /// The cataloged photos, in capture order — the map's pins and the
  /// preview read this.
  List<StoredPhoto> get photos => store.photos;

  /// Takes a photo through the injected [photoSource] and catalogs it at
  /// [position] — the freshest fix in hand at press time (the session's
  /// live fix while recording, else the latest located fix): the page
  /// picks it, the model never requests a second GPS fix for a photo (a
  /// stale-but-close position is accepted and is editable afterward).
  ///
  /// The captured bytes copy into the store's `photos/` directory (the
  /// app owns the copy) and the catalog notifies once, so the new pin
  /// mounts like an imported track does. Declined and failed captures
  /// change nothing.
  Future<PhotoAddResult> takePhoto(
    LatLng position, {
    DateTime? takenAt,
  }) async {
    final outcome = await photoSource.capture();
    switch (outcome) {
      case PhotoCaptureSucceeded(:final bytes):
        final photo = store.addPhoto(
          bytes,
          lat: position.latitude,
          lon: position.longitude,
          takenAt: takenAt ?? DateTime.now(),
        );
        DebugLog.instance.info(
          'photo: saved ${photo.id} at '
          '${position.latitude.toStringAsFixed(6)},'
          '${position.longitude.toStringAsFixed(6)}',
        );
        notifyListeners();
        return PhotoAdded(photo);
      case PhotoCaptureDeclined():
        DebugLog.instance.info('photo: capture declined');
        return const PhotoAddDeclined();
      case PhotoCaptureFailed(:final reason):
        DebugLog.instance.warn('photo: capture failed: $reason');
        return const PhotoAddFailed();
    }
  }

  /// Removes a photo (its catalog entry and the app's own file copy).
  Future<void> deletePhoto(StoredPhoto photo) async {
    await store.removePhoto(photo);
    notifyListeners();
  }

  /// User-initiated gallery export of a photo (the preview's Save to
  /// gallery): a MediaStore copy of the app's own file through the host
  /// channel. True when the gallery accepted it. The stored photo is
  /// untouched either way.
  Future<bool> savePhotoToGallery(StoredPhoto photo) =>
      savePhotoToGalleryFile(
        store.photoFileFor(photo).path,
        photo.file,
      );

  /// Opens the system share sheet for a photo (the preview's Share):
  /// ACTION_SEND over the app's FileProvider. Fire-and-forget — the
  /// receiving app's outcome is not reported back.
  Future<void> sharePhoto(StoredPhoto photo) =>
      sharePhotoFile(store.photoFileFor(photo).path);

  /// Moves a photo to a corrected position (the preview's Reposition
  /// action settled on a map tap) and persists it.
  Future<void> repositionPhoto(StoredPhoto photo, LatLng position) async {
    await store.updatePhotoPosition(
      photo,
      lat: position.latitude,
      lon: position.longitude,
    );
    notifyListeners();
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

  /// The selected aggregate's member ids, captured at selection time.
  /// Aggregates are built from visible tracks only, so a member hidden
  /// while selected leaves [aggregates] — this list is what member-picking
  /// mode still considers until the selection clears.
  List<String>? selectedMemberIds;

  /// Member-picking mode: while an aggregate is selected, the tracks
  /// button toggles drawing each member track on the map in its own color
  /// so a map tap can pick one. Cleared together with the selection.
  bool memberPicking = false;

  /// The member track picked by a map tap in member-picking mode (the one
  /// that glows and whose actions the bar shows), or null.
  String? pickedMemberId;

  void _clearSelectionState() {
    selectedAnchor = null;
    selectedMemberIds = null;
    memberPicking = false;
    pickedMemberId = null;
  }

  /// Drops the selection: anchor, captured member list, and picking state
  /// all go.
  void clearSelection() {
    if (selectedAnchor == null && selectedMemberIds == null &&
        !memberPicking && pickedMemberId == null) {
      return;
    }
    _clearSelectionState();
    notifyListeners();
  }

  AggregateTrack? get selectedAggregate {
    final anchor = selectedAnchor;
    if (anchor == null) return null;
    for (final a in aggregates) {
      if (a.anchorId == anchor) return a;
    }
    // The aggregate is gone (hidden, deleted): drop the selection.
    _clearSelectionState();
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
          selectedMemberIds = a.trackIds;
          notifyListeners();
          return true;
        }
      }
    }
    if (clearIfMiss && selectedAnchor != null) {
      _clearSelectionState();
      notifyListeners();
    }
    return false;
  }

  /// Toggles member-picking mode for the current selection (the selection
  /// bar's tracks button). Exiting clears any picked track.
  void toggleMemberPicking() {
    if (selectedAnchor == null) return;
    memberPicking = !memberPicking;
    if (!memberPicking) pickedMemberId = null;
    notifyListeners();
  }

  /// Exits member-picking mode (a map tap that missed every lane, or the
  /// tracks button toggling off): clears the pick and the mode.
  void exitMemberPicking() {
    if (!memberPicking && pickedMemberId == null) return;
    memberPicking = false;
    pickedMemberId = null;
    notifyListeners();
  }

  /// Picks a member track of the current selection. The page resolves the
  /// tapped lane in screen space (hit-testing the same offset geometry it
  /// draws — see MapPage) and hands the id over; the model only owns the
  /// pick state.
  void pickMember(String id) {
    if (pickedMemberId == id) return;
    pickedMemberId = id;
    notifyListeners();
  }

  /// Clears the pick without leaving member-picking mode.
  void clearPick() {
    if (pickedMemberId == null) return;
    pickedMemberId = null;
    notifyListeners();
  }

  /// The per-member tint key + lane assignments for member-picking mode:
  /// near tracks get different palette colors and every member its own
  /// draw lane (see [assignMemberColors]). Memoized on the captured member
  /// list, like [aggregates].
  Map<String, MemberColorAssignment>? _memberAssignments;
  String? _memberAssignmentsSource;

  Map<String, MemberColorAssignment> get memberAssignments {
    final ids = selectedMemberIds;
    if (ids == null) return const {};
    final source = ids.join('|');
    if (source != _memberAssignmentsSource) {
      _memberAssignmentsSource = source;
      final byId = {for (final t in store.tracks) t.id: t};
      _memberAssignments = assignMemberColors(
        [
          for (final id in ids)
            if (byId[id] != null)
              AggregateInput(
                id: id,
                points: pointsOf(byId[id]!),
                startTimeUtc: byId[id]!.startTimeUtc,
              ),
        ],
        palette: explorationTints.keys.toList(),
      );
    }
    return _memberAssignments!;
  }

  /// A stored track's points, loading and caching the file on first use —
  /// works for hidden tracks too (ghost lanes in picking mode need them),
  /// unlike [visibleTracks].
  List<LatLng> pointsOf(StoredTrack t) {
    final cached = imports.cachedPoints(t);
    if (cached != null) return cached;
    final data = store.loadPoints(t);
    if (data == null) return const [];
    final pts = data.points.map((p) => LatLng(p.lat, p.lon)).toList();
    imports.rememberPoints(t, pts);
    return pts;
  }

  /// Hides the picked member track (the bubble's "Hide this track") and
  /// clears the pick.
  Future<void> hidePickedMember() async {
    final picked = pickedMemberId;
    if (picked == null) return;
    pickedMemberId = null;
    await setSelectedMemberVisible(picked, false);
  }

  /// Re-shows the picked member track (a ghost lane's bubble action) and
  /// clears the pick.
  Future<void> showPickedMember() async {
    final picked = pickedMemberId;
    if (picked == null) return;
    pickedMemberId = null;
    await setSelectedMemberVisible(picked, true);
  }

  /// Shows only the picked member track: hides every other visible member
  /// of the selection, then clears the pick. The selection re-anchors if
  /// the hidden anchor was among them (see [_reanchorIfAnchorHidden]).
  Future<void> showOnlyPickedMember() async {
    final picked = pickedMemberId;
    if (picked == null) return;
    pickedMemberId = null;
    for (final id in selectedMemberIds ?? const <String>[]) {
      if (id == picked) continue;
      final matches = store.tracks.where((s) => s.id == id);
      final t = matches.isEmpty ? null : matches.first;
      if (t != null && t.visible) {
        await store.setVisible(t, false);
        player.trackRemoved(id);
      }
    }
    await _reanchorIfAnchorHidden();
    _catalogDataChanged();
  }

  /// Hides the selected aggregate's member tracks (deselect = the
  /// underlying tracks leave the map) and drops the selection.
  /// Bumped when the selected aggregate is hidden from the selection bar;
  /// MapPage compares against the value it last handled (the
  /// fitRequestEpoch pattern) to fire the undo toast.
  int aggregateHideEpoch = 0;

  /// The member ids hidden by the last [hideSelectedAggregate] — the undo
  /// toast's target. Session-only; nothing persists a hidden area.
  List<String>? _lastHiddenAggregateIds;

  Future<void> hideSelectedAggregate() async {
    final selected = selectedAggregate;
    if (selected == null) return;
    _clearSelectionState();
    final hidden = <String>[];
    for (final id in selected.trackIds) {
      final matches = store.tracks.where((s) => s.id == id);
      final t = matches.isEmpty ? null : matches.first;
      if (t != null && t.visible) {
        await store.setVisible(t, false);
        hidden.add(id);
      }
    }
    _lastHiddenAggregateIds = hidden;
    aggregateHideEpoch++;
    _catalogDataChanged();
  }

  /// Re-shows the tracks hidden by the last [hideSelectedAggregate] (the
  /// undo toast's action): members deleted meanwhile are skipped.
  Future<void> undoLastHide() async {
    final ids = _lastHiddenAggregateIds;
    if (ids == null) return;
    _lastHiddenAggregateIds = null;
    for (final id in ids) {
      final matches = store.tracks.where((s) => s.id == id);
      final t = matches.isEmpty ? null : matches.first;
      if (t != null && !t.visible) await store.setVisible(t, true);
    }
    _catalogDataChanged();
  }

  /// After members were hidden: if the selection's anchor track is no
  /// longer visible, move the selection to the aggregate of the first
  /// remaining visible member and migrate the persisted color override to
  /// the new anchor. (A still-visible anchor stays the anchor of its
  /// re-clustered aggregate — hiding members never introduces an earlier
  /// one.) If no member remains visible, the aggregate is gone and the
  /// [selectedAggregate] getter's fallback drops the selection.
  Future<void> _reanchorIfAnchorHidden() async {
    final anchor = selectedAnchor;
    if (anchor == null) return;
    final anchorMatches = store.tracks.where((s) => s.id == anchor);
    if (anchorMatches.isNotEmpty && anchorMatches.first.visible) return;
    for (final id in selectedMemberIds ?? const <String>[]) {
      if (id == anchor) continue;
      final matches = store.tracks.where((s) => s.id == id);
      if (matches.isEmpty || !matches.first.visible) continue;
      for (final a in aggregates) {
        if (a.trackIds.contains(id)) {
          if (a.anchorId != anchor) {
            final color = store.aggregateColor(anchor);
            if (color != null) {
              await store.saveAggregateColor(a.anchorId, color);
              await store.saveAggregateColor(anchor, '');
            }
            selectedAnchor = a.anchorId;
          }
          return;
        }
      }
    }
  }

  /// Shows or hides one member track of the current selection (the picked
  /// track's hide action, or the drawer). Hiding a replaying track stops
  /// its replay (same rule as delete — a marker on a hidden track would be
  /// a ghost of hidden data). Hiding the selection's anchor re-anchors the
  /// selection (see [_reanchorIfAnchorHidden]).
  Future<void> setSelectedMemberVisible(String trackId, bool visible) async {
    final matches = store.tracks.where((s) => s.id == trackId);
    final t = matches.isEmpty ? null : matches.first;
    if (t == null || t.visible == visible) return;
    await store.setVisible(t, visible);
    if (!visible) player.trackRemoved(trackId);
    if (!visible) await _reanchorIfAnchorHidden();
    _catalogDataChanged();
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

  /// Bumped whenever a fit request fires; MapPage compares against the
  /// value it last handled (the importEpoch pattern).
  int fitRequestEpoch = 0;

  /// The track a pending fit targets: the tapped track's own points, not
  /// its whole aggregate's. MapPage consumes it with the bumped
  /// [fitRequestEpoch] and clears it; null falls back to the aggregate
  /// fit (nothing else sets per-track fits today).
  String? fitTrackId;

  /// The track list's tile tap (name or the row below): asks the camera
  /// to jump to that track's own points — nothing else. It never selects
  /// an aggregate and never toggles visibility; the checkbox is the
  /// tile's only selecting/hiding element. No-op for a hidden track
  /// (it has no points on the map to fit to until it is re-shown).
  void fitTrack(StoredTrack t) {
    if (!t.visible) return;
    fitTrackId = t.id;
    fitRequestEpoch++;
    notifyListeners();
  }

  @override
  void dispose() {
    recorder.recordingLive.dispose();
    player.playbackLive.dispose();
    super.dispose();
  }
}
