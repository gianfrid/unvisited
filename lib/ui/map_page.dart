import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n/app_strings.dart';
import '../recording/recording_session.dart';
import '../tile_source.dart';
import 'app_model.dart';
import 'fog_of_war.dart';
import 'map_actions.dart';
import 'recording_dashboard.dart';
import 'settings_sheet.dart';
import 'track_colors.dart';
import 'track_list.dart';
import 'zoom_slider.dart';

class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
    required this.model,
    required this.cacheDir,
    this.versionFuture,
    this.locationSupported = false,
  });

  final AppModel model;
  final Directory cacheDir;

  /// Build time shown in the Settings sheet's About card; tests inject a
  /// fixed value so no git process is spawned from a widget test.
  final Future<String>? versionFuture;

  /// Whether the platform has a location plugin. When false (desktop
  /// Linux) the Locate action is not offered at all — it could only ever
  /// fail there.
  final bool locationSupported;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  StreamSubscription<MapEvent>? _mapEvents;
  int _seenImportEpoch = 0;

  static const _berlinCenter = LatLng(52.5200, 13.4050);
  static const _startZoom = 13.0;
  static const _fitPadding = EdgeInsets.all(64);

  /// Zoom the locate action settles on: close enough to see the streets
  /// around the user, far enough to keep their bearings.
  static const _locateZoom = 16.0;

  @override
  void initState() {
    super.initState();
    _seenImportEpoch = widget.model.importEpoch;
    _seenFitRequestEpoch = widget.model.fitRequestEpoch;
    // Probe-and-create the cache directory up front. The caching provider
    // sets itself up in a fire-and-forget block: if directory creation
    // fails there, its initializer never completes and every tile read
    // awaits it forever - tiles hang with no error and the map stays
    // grey (fresh install included). When the directory cannot be
    // created, disable caching so tiles still load, network-only.
    _cacheUsable = _probeCacheDirectory(widget.cacheDir);
    if (_cacheUsable) {
      BuiltInMapCachingProvider.getOrCreateInstance(
        cacheDirectory: widget.cacheDir.path,
        maxCacheSize: 500 * 1024 * 1024, // 500 MB cache limit
      );
    }
    widget.model.addListener(_onModelChanged);
    // Cross a zoom level: the fog coarseness is keyed to the zoom, so the
    // overlay must be rebuilt when the view moves between zoom levels
    // (the cell grid doubles per band — see fogCellSizeFor).
    _mapEvents = _mapController.mapEventStream.listen((event) {
      final cell = fogCellSizeFor(
        zoom: event.camera.zoom,
        latitude: event.camera.center.latitude,
      );
      var dirty = cell != _fogCellSize;
      if (!dirty && _locatedPosition != null) {
        // The position marker shows the last fix; once the user pans away
        // from it, it would sit somewhere they are not — drop it.
        final drift = const Distance().distance(
          event.camera.center,
          _locatedPosition!,
        );
        if (drift > _markerClearDistance) {
          _locatedPosition = null;
          dirty = true;
        }
      }
      if (dirty) setState(() => _fogCellSize = cell);
    });
    // Start silently with the last saved position (never prompting) and
    // let a live fix override it once it arrives. With no location
    // permission granted yet this is a no-op — only the locate button
    // asks.
    _silentPositionUpdate();
    _startFixRetryTimer();
  }

  late final bool _cacheUsable;

  /// Current fog-cell edge for the explored overlay; updated from map
  /// events in initState and read when the circles are built.
  double _fogCellSize = baseCellSizeMeters;

  /// True while a locate attempt is in flight. Acquiring a fix takes
  /// seconds (longer on a cold GPS), so the button shows a spinner and
  /// ignores further taps instead of looking dead.
  bool _locating = false;

  /// The last located fix, shown as a "you are here" marker. Ephemeral
  /// UI state: cleared when the user pans away from it (see the map event
  /// listener) so it never points at a spot the user has left behind.
  LatLng? _locatedPosition;

  /// How far the map center may drift from [_locatedPosition] before the
  /// marker is dropped. Roughly half a city block at the locate zoom.
  static const _markerClearDistance = 50.0; // meters

  /// Whether a real position fix has actually been obtained. Distinct
  /// from [_locatedPosition] — which pan-drop clears — so panning away
  /// from the fix never hides a working Record button. Only a real fix
  /// (the silent poll or the Locate button) sets it; where no fix can
  /// come (GPS off, no plugin) it stays false and Record stays hidden
  /// instead of sitting there as a dead button.
  bool _gpsWorking = false;

  /// How long the page waits before another silent fix attempt while
  /// [_gpsWorking] is still false: GPS may have been off or cold at
  /// startup; once it comes up, the button must appear without the user
  /// restarting the app.
  static const _fixRetryInterval = Duration(seconds: 30);
  Timer? _fixRetryTimer;

  /// Arms the silent retry loop. The startup poll and the retries share
  /// [_silentPositionUpdate]; every caller that sees a fix cancels the
  /// loop — no retries once a fix exists.
  void _startFixRetryTimer() {
    if (!widget.locationSupported) return;
    _fixRetryTimer?.cancel();
    if (_gpsWorking) return;
    _fixRetryTimer = Timer.periodic(
      _fixRetryInterval,
      (_) => _silentPositionUpdate(),
    );
  }

  /// The recording dashboard (HUD chip, stats panel, screen latch,
  /// follow-camera): see `RecordingDashboard`. Its state is reached by
  /// key — the locate button's shortcut re-arms the follow.
  final _dashboardKey = GlobalKey<RecordingDashboardState>();

  /// The fit-request epoch MapPage handled last (see the import epoch):
  /// a track-tile tap asks for a fit to its aggregate.
  int _seenFitRequestEpoch = 0;

  /// Cached unlock centers keyed to the current overlay inputs (visible
  /// track ids + cell size), so pans and transient item rebuilds do not
  /// re-walk every track point.
  /// Per-aggregate unlock centers cache: aggregate cache key (anchor +
  /// member ids + fog cell size) -> its grid centers.
  final _fogCentersByAnchor = <String, List<LatLng>>{};

  /// Creates the provider's `fm_cache` subdirectory synchronously; fails
  /// fast when the location is unwritable.
  static bool _probeCacheDirectory(Directory cacheDir) {
    try {
      Directory('${cacheDir.path}${Platform.pathSeparator}fm_cache')
          .createSync(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  void dispose() {
    _mapEvents?.cancel();
    _fixRetryTimer?.cancel();
    widget.model.removeListener(_onModelChanged);
    super.dispose();
  }

  void _onModelChanged() {
    if (!mounted) return;
    final epoch = widget.model.importEpoch;
    if (epoch != _seenImportEpoch) {
      _seenImportEpoch = epoch;
      final pts = widget.model.lastImportedPoints;
      if (pts.isNotEmpty) {
        // Center on what was just imported.
        _fitWhenSized(
          CameraFit.coordinates(coordinates: pts, padding: _fitPadding),
        );
      }
    }
    // A track-tile tap selects its aggregate and asks for a fit to it
    // (the plain select path — a map tap — never sets the epoch).
    final fitEpoch = widget.model.fitRequestEpoch;
    if (fitEpoch != _seenFitRequestEpoch) {
      _seenFitRequestEpoch = fitEpoch;
      final selected = widget.model.selectedAggregate;
      if (selected != null && selected.points.isNotEmpty) {
        _fitWhenSized(
          CameraFit.coordinates(
            coordinates: selected.points,
            padding: _fitPadding,
          ),
        );
      }
    }
    setState(() {});
  }

  /// Tap tolerance for aggregate selection: ~24 screen px worth of meters
  /// at the tap's zoom.
  double _hitToleranceMeters(LatLng tap) =>
      24 *
      groundResolution(
        zoom: _mapController.camera.zoom,
        latitude: tap.latitude,
      );

  void _onMapTap(LatLng tap) {
    if (widget.model.isRecording) return; // the recording UI owns taps then
    widget.model.selectAggregateAt(
      tap,
      toleranceMeters: _hitToleranceMeters(tap),
      clearIfMiss: widget.model.selectedAnchor != null,
    );
  }

  /// The selected aggregate's highlight: the same cells the fog grid
  /// draws, computed over just the selection's points, in a more transparent
  /// opaque version of the aggregate's own resolved color so the selection
  /// reads on top of the shared overlay.
  List<CircleMarker> _selectionHighlight() {
    final selected = widget.model.selectedAggregate;
    if (selected == null) return const [];
    final key = widget.model.aggregateTintKeys[selected.anchorId];
    final tint = exploredAreaColor(key ?? defaultTintKey);
    final highlight = tint.withValues(alpha: (tint.a + 0.55).clamp(0.0, 1.0));
    return [
      for (final c in unlockCenters(
        selected.points,
        cellSizeMeters: _fogCellSize,
      ))
        CircleMarker(
          point: c,
          color: highlight,
          radius: unlockRadiusForCell(_fogCellSize),
          useRadiusInMeter: true,
        ),
    ];
  }

  /// Fits the camera, but only once it has a real size. At launch the map
  /// can still be laid out against zero-sized constraints (the window
  /// surface is not ready yet on Android or Wayland); fitting against that
  /// degenerates the camera and the tile layer renders nothing until the
  /// user pans - the map starts grey. Retry a few frames until the surface
  /// is sized, then fit.
  void _fitWhenSized(CameraFit fit) {
    var attempts = 0;
    void attempt() {
      if (!mounted) return;
      final size = _mapController.camera.nonRotatedSize;
      if (size.width <= 0 || size.height <= 0) {
        if (attempts++ < 30) {
          WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
        }
        return;
      }
      _mapController.fitCamera(fit);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
  }

  Future<void> _pickFolder() async {
    final strings = AppStrings.ofContext(context);
    try {
      final summary = await widget.model.importViaDirectoryPicker();
      if (summary != null) _toast(summary.describe(strings));
    } on PlatformException catch (e) {
      _toast('${strings.folderImportFailed}: ${e.message ?? e.code}');
    }
  }

  /// The recording marker: at the last accepted fix. With course-up on
  /// (`mapRotation == 'on'`) the nose is pinned screen-up — the camera
  /// carries the course, and pinning keeps the marker from swinging while
  /// the rotation eases in. With course-up off the marker rotates to the
  /// course on screen — a geographic bearing shows at screen bearing
  /// course + camera rotation, since a positive rotation turns the map
  /// clockwise — so it follows the direction of travel. A fix without a
  /// heading and no bearing yet renders unrotated. Rebuilt per fix through
  /// the recording-live channel; still a direct child of the map's layer
  /// stack, which its marker positioning depends on.
  List<Widget> _recordingMarkers() {
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return const [];
    return [
      ListenableBuilder(
        listenable: widget.model.recordingLive,
        builder: (context, _) => MarkerLayer(
          markers: [
            Marker(
              point: LatLng(lat, lon),
              width: 44,
              height: 44,
              child: Transform.rotate(
                key: const ValueKey('recording-marker-rotate'),
                // Course-up on: pinned screen-up. Off: the nose follows the
                // course on screen (bearing + rotation, positive rotation
                // turns the map clockwise).
                angle: widget.model.mapRotation == 'on'
                    ? 0
                    : ((session!.currentCourse ?? 0) +
                            _mapController.camera.rotation) *
                        math.pi /
                        180,
                child: Container(
                  key: const ValueKey('recording-marker-disc'),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.surface,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                    boxShadow: const [
                      BoxShadow(blurRadius: 4, color: Colors.black38),
                    ],
                  ),
                  child: Icon(
                    Icons.navigation,
                    size: 32,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// Centers the map on the last saved position while waiting for a live
  /// fix (and moves onto the fix once it arrives). Never asks for
  /// permission; when none is granted or the platform has no location
  /// support (desktop Linux) this leaves the camera where it was.
  Future<void> _silentPositionUpdate() async {
    final pos = await widget.model.currentPosition(prompt: false);
    if (!mounted || pos == null) return;
    // The fix is real: it opens the Record button and shows the marker.
    setState(() => _locatedPosition = pos);
    _gpsWorking = true;
    _fixRetryTimer?.cancel();
    // Saved tracks fit the whole catalog; only the empty map follows the
    // position so imports and track fits are never fought over.
    if (widget.model.visibleTracks.isNotEmpty) return;
    _mapController.move(pos, _mapController.camera.zoom);
  }

  /// Locate button: prompts for permission when none has been granted,
  /// then centers the map on the current position and zooms in. When no
  /// position can be had, says why — a silent no-op reads as a broken
  /// button.
  ///
  /// While a session runs (recording or paused) the tap is the way back to
  /// the follow after panning away: the session's own fix is fresher than
  /// any new attempt and permission is already granted, so the branch
  /// re-centers on it at the user's zoom and re-arms the follow — both the
  /// camera and the course-up rotation come back with the next fix. The
  /// shortcut returns before [_locating] is set: it is instant, no
  /// spinner. Without a session fix yet (cold GPS) it falls through to the
  /// real attempt; its success arms the follow too while recording.
  ///
  /// The whole attempt is bracketed by [_locating], so the toolbar button
  /// turns into a spinner for as long as the fix takes. Re-entrant taps
  /// are ignored: a second GPS request would not answer any sooner.
  Future<void> _locate() async {
    if (_locating) return;
    if (widget.model.isRecording) {
      final session = widget.model.recording;
      final lat = session?.currentLat;
      final lon = session?.currentLon;
      if (lat != null && lon != null) {
        // The follow-camera's shortcut back: re-center on the session's
        // own fix at the user's zoom and re-arm (camera and course-up
        // rotation both) — no second GPS request, no spinner.
        _dashboardKey.currentState?.rearmFollow();
        return;
      }
      // No session fix yet: a real attempt is the only way to answer
      // "where am I"; its success arms the follow below.
    }
    final strings = AppStrings.ofContext(context);
    setState(() => _locating = true);
    try {
      final result = await widget.model.locate(prompt: true);
      if (!mounted) return;
      final pos = result.position;
      if (pos == null) {
        // No stale marker from an earlier fix: the user asked where they
        // are and the answer is "unknown".
        setState(() => _locatedPosition = null);
        _toast(_locateFailureMessage(strings, result.failure));
        return;
      }
      // The attempt landed while a session runs: its fix is the one to
      // follow — arm the follow so the next fix takes the camera over.
      if (widget.model.isRecording) _dashboardKey.currentState?.armFollow();
      setState(() => _locatedPosition = pos);
      // A deliberated locate is also evidence the GPS works: it opens the
      // Record button, no silent retry needed.
      _gpsWorking = true;
      _fixRetryTimer?.cancel();
      // While a session runs the follow takes the camera over from here,
      // and its zoom stays the user's; the locate-zoom settle is for the
      // plain locate. Either way, never zoom out: a user already closer
      // than the locate zoom keeps their detail level.
      final zoom = widget.model.isRecording
          ? _mapController.camera.zoom
          : (_mapController.camera.zoom < _locateZoom
                ? _locateZoom
                : _mapController.camera.zoom);
      _mapController.move(pos, zoom);
    } finally {
      // Also runs when the widget went away mid-flight; the mounted check
      // keeps setState off a disposed element.
      if (mounted) setState(() => _locating = false);
    }
  }

  static String _locateFailureMessage(
    AppStrings strings,
    LocationFailure? failure,
  ) {
    switch (failure) {
      case LocationFailure.serviceDisabled:
        return strings.locationServiceDisabled;
      case LocationFailure.permissionDenied:
        return strings.locationPermissionDenied;
      case LocationFailure.permissionBlocked:
        return strings.locationPermissionBlocked;
      case LocationFailure.unavailable:
      case null:
        return strings.locationUnavailable;
    }
  }

  /// One entry point for imports: single files and folder scans flow
  /// through the same unified pipeline, so one button is enough.
  Future<void> _chooseImport() async {
    final strings = AppStrings.ofContext(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(strings.importTrackFiles),
              subtitle: Text(strings.importTrackFilesSubtitle),
              onTap: () => Navigator.of(context).pop('files'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(strings.importFolder),
              subtitle: Text(strings.importFolderSubtitle),
              onTap: () => Navigator.of(context).pop('folder'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'folder') {
      await _pickFolder();
    } else if (choice == 'files') {
      await _pickFiles();
    }
  }

  Future<void> _pickFiles() async {
    final strings = AppStrings.ofContext(context);
    final summary = await widget.model.importViaFilePicker();
    _toast(summary.describe(strings));
  }

  /// Settings sheet: About card (build date) and the delete-all action.
  Future<void> _openSettings() async {
    final strings = AppStrings.ofContext(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SettingsSheet(
        model: widget.model,
        trackCount: widget.model.tracks.length,
        versionFuture: widget.versionFuture,
      ),
    );
    if (!mounted || choice != 'deleteAll') return;
    final trackCount = widget.model.tracks.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.deleteAllTracksQuestion),
        content: Text(strings.deleteAllTracksBody(trackCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await widget.model.deleteAll();
    _toast(strings.allTracksDeleted);
  }

  void _toast(String message) => showMapToast(context, message);

  /// Fog-of-war overlay: one translucent circle per unlocked grid cell, in
  /// the single exploration tint. Track polylines are gone by design — the
  /// union of circles is how a visited area shows on the map.
  /// The live trace as age-faded polylines: points are bucketed into
  /// 30 s age buckets, and each bucket's alpha scales linearly from the
  /// full trace color down to [traceFadeMinAlpha] over [traceFadeWindow]
  /// — an old, retreated stretch fades to almost transparent while the
  /// fresh end stays solid, so direction of travel stays readable.
  static const Duration traceFadeWindow = Duration(minutes: 5);
  static const Duration traceFadeBucket = Duration(seconds: 30);
  static const double traceFadeMinAlpha = 0.1;

  List<Polyline> _liveTracePolylines(RecordingSession session) {
    final base = recordingTraceColor(widget.model.recordingTint);
    final now = DateTime.now();
    final out = <Polyline>[];
    final segments = session.liveSegments;
    final times = session.liveSegmentTimes;
    for (var s = 0; s < segments.length; s++) {
      final seg = segments[s];
      if (seg.length < 2) continue;
      final segTimes = times[s];
      // Bucket index per point; a bucket keeps the points consecutive in
      // the segment so each bucket renders as one polyline.
      var bucketStart = 0;
      for (var i = 1; i <= seg.length; i++) {
        final newBucket =
            i == seg.length ||
            (now.difference(segTimes[i]).inSeconds ~/
                    traceFadeBucket.inSeconds) !=
                (now.difference(segTimes[i - 1]).inSeconds ~/
                    traceFadeBucket.inSeconds);
        if (!newBucket) continue;
        if (i - bucketStart < 2) {
          bucketStart = i;
          continue;
        }
        final age = now.difference(segTimes[i - 1]);
        final fade = 1.0 -
            (1.0 - traceFadeMinAlpha) *
                (age.inMilliseconds / traceFadeWindow.inMilliseconds).clamp(
                  0.0,
                  1.0,
                );
        out.add(
          Polyline(
            points: seg.sublist(bucketStart, i),
            color: base.withValues(alpha: (base.a * 255.0).round() / 255.0 * fade),
            strokeWidth: 4,
          ),
        );
        bucketStart = i;
      }
    }
    return out;
  }

  List<CircleMarker> _buildFogCircles(List<MapTrack> tracks) {
    final tintKeys = widget.model.aggregateTintKeys;
    final out = <CircleMarker>[];
    final radius = unlockRadiusForCell(_fogCellSize);
    for (final a in widget.model.aggregates) {
      final key =
          '${[for (final t in a.members) t.id].join('|')}@$_fogCellSize';
      var centers = _fogCentersByAnchor[key];
      if (centers == null) {
        centers = unlockCenters(a.points, cellSizeMeters: _fogCellSize);
        _fogCentersByAnchor[key] = centers;
      }
      final tint = exploredAreaColor(tintKeys[a.anchorId] ?? defaultTintKey);
      out.addAll([
        for (final c in centers)
          CircleMarker(
            point: c,
            color: tint,
            radius: radius,
            useRadiusInMeter: true,
          ),
      ]);
    }
    return out;
  }

  /// Unlocked road corridors: the matched sub-polylines persisted on each
  /// visible track, drawn fat and translucent in the track's aggregate
  /// tint so corridors and their circles read as one overlay. A way
  /// unlocked by several tracks draws once (the corridors usually
  /// coincide; double-drawing would double-darken the shared stretch).
  /// flutter_map culls off-screen polylines and simplifies them per zoom;
  /// LOD variants are deferred until catalog scale demands them.
  List<Polyline> _buildCorridors(List<MapTrack> tracks) {
    final tintKeys = widget.model.aggregateTintKeys;
    final anchors = <String, String>{};
    for (final a in widget.model.aggregates) {
      for (final id in a.trackIds) {
        anchors[id] = tintKeys[a.anchorId] ?? defaultTintKey;
      }
    }
    final seen = <String>{};
    final out = <Polyline>[];
    for (final t in tracks) {
      final tint = exploredAreaColor(anchors[t.meta.id] ?? defaultTintKey);
      t.meta.unlockedWays.forEach((wayId, corridors) {
        if (!seen.add(wayId)) return;
        for (final corridor in corridors) {
          if (corridor.length < 2) continue;
          out.add(Polyline(points: corridor, strokeWidth: 6, color: tint));
        }
      });
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final mapTracks = widget.model.visibleTracks;
    final corridors = _buildCorridors(mapTracks);
    return Scaffold(
      // No app bar: the labeled actions live on a compact floating
      // toolbar that hugs its content at the top-right corner, so the
      // map map keeps rendering behind it instead of being pushed down
      // by a full-width bar.
      endDrawerEnableOpenDragGesture: false,
      endDrawer: TrackDrawer(model: widget.model),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              // Start at the last saved position (Berlin as the very first
              // run fallback); a live fix refines this after startup.
              initialCenter: widget.model.savedPosition ?? _berlinCenter,
              initialZoom: _startZoom,
              minZoom: mapMinZoom,
              maxZoom: mapMaxZoom,
              // Startup fit for saved tracks goes through the engine path:
              // flutter_map applies it only once the camera has a real
              // size, guarding against the zero-sized startup constraints
              // of a fresh window surface. A manual post-frame fitCamera
              // here degenerates the camera instead and the map stays
              // grey until the first pan.
              initialCameraFit: mapTracks.isEmpty
                  ? null
                  : CameraFit.coordinates(
                      coordinates: [for (final t in mapTracks) ...t.points],
                      padding: _fitPadding,
                    ),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
                keyboardOptions: KeyboardOptions(
                  enableArrowKeysPanning: true,
                  enableRFZooming: true, // Enable R/F keys for zoom
                  autofocus: true,
                ),
              ),
              // Tap within tolerance of an aggregate's points selects it
              // (the selection bar appears below); a tap on empty map
              // deselects, which is the bar's way away too.
              onTap: (tapDetail, tap) => _onMapTap(tap),
            ),
            children: [
              TileLayer(
                urlTemplate: tileUrlTemplateFor(widget.model.tileLayer),
                // CyclOSM host-rotates with {s}; the standard OSM template
                // has no {s}, so its subdomains value is unused.
                subdomains: widget.model.tileLayer == 'cycle'
                    ? cycleTileSubdomains
                    : const <String>['abc'],
                userAgentPackageName: tileUserAgent,
                // Dark mode: both tile styles are light-only, so a dark
                // UI would leave a bright map. Darken client-side with
                // flutter_map's built-in inverted-matrix builder — no new
                // tile endpoint (SPEC forbids one); the result is a dimmed
                // map rather than true dark cartography, the accepted
                // trade-off.
                tileBuilder: Theme.of(context).brightness == Brightness.dark
                    ? darkModeTileBuilder
                    : null,
                tileProvider: NetworkTileProvider(
                  // Not const: TileLayer's constructor inserts a default
                  // User-Agent into the provider's headers when absent, and
                  // that mutation throws on a const (unmodifiable) map.
                  headers: {HttpHeaders.userAgentHeader: tileUserAgent},
                  // flutter_map aborts in-flight requests for tiles that
                  // leave the visible range (the startup camera refit and
                  // panning prune tiles constantly). With aborts on, every
                  // request kept dying before the first byte arrived and the
                  // map stayed gray although the server was fine. Completed
                  // requests also populate the offline tile cache, which is
                  // this app's point - so we let them finish.
                  abortObsoleteRequests: false,
                  // Network-only tiles when the cache directory is unusable;
                  // null keeps the built-in caching provider.
                  cachingProvider: _cacheUsable
                      ? null
                      : const DisabledMapCachingProvider(),
                ),
              ),
              CircleLayer(circles: _buildFogCircles(mapTracks)),
              // Unlocked road corridors (fog-of-war for streets), above
              // the circles so the corridor reads on top of the blobs.
              if (corridors.isNotEmpty) PolylineLayer(polylines: corridors),
              // The selected aggregate's highlight, above corridors so the
              // selection reads on top of the overlay.
              if (widget.model.selectedAnchor != null)
                CircleLayer(circles: _selectionHighlight()),
              // The live recording trace: the session's accepted fixes as
              // polylines, translucent in a fixed recording red — outside
              // the catalog tint family, clearly in-progress. Above the
              // fog, below the course-up marker. Absent when no session
              // runs; after stop the finalized track is a catalog track.
              // Scoped to the per-fix channel: a fix rebuilds this layer
              // and nothing above it in this children list.
              if (widget.model.recording != null)
                ListenableBuilder(
                  listenable: widget.model.recordingLive,
                  builder: (context, _) => PolylineLayer(
                    polylines: _liveTracePolylines(
                      widget.model.recording!,
                    ),
                  ),
                ),
              // "You are here" marker for the last located fix; absent
              // until a fix exists and dropped when the user pans away.
              if (_locatedPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _locatedPosition!,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: Icon(
                        Icons.location_on,
                        size: 40,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              // The recording marker (course-up) rides above the locate
              // one so a session's fixes read on top of a startup fix.
              ..._recordingMarkers(),
              RichAttributionWidget(
                // The default flutter_map logo badge is redundant next to
                // the OSM attribution this app already shows.
                showFlutterMapAttribution: false,
                attributions: [
                  TextSourceAttribution(
                    tileAttribution(widget.model.tileLayer),
                    onTap: () {},
                  ),
                ],
              ),
            ],
          ),
          // Lateral zoom control on the configured edge (settings),
          // vertically centered in the free band between the toolbar and
          // the bottom. SafeArea keeps the band inset-aware; the right
          // side still starts below the toolbar band, so the two never
          // overlap on narrow screens (the toolbar is centered and can
          // reach the edges) — the left side has no toolbar there.
          Positioned(
            top: 0,
            bottom: 0,
            left: widget.model.zoomSliderSide == 'left' ? 12 : null,
            right: widget.model.zoomSliderSide == 'left' ? null : 12,
            child: SafeArea(
              minimum: EdgeInsets.only(
                top: widget.model.zoomSliderSide == 'left'
                    ? 16
                    : kToolbarHeight + 24,
                bottom: 16,
              ),
              child: Center(child: ZoomSlider(controller: _mapController)),
            ),
          ),
          // Compact floating toolbar at the top, centered across the
          // map's top edge instead of a full-width app bar — the only
          // overlay up there now; the selection bar and the recording
          // chip live in the bottom column below.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              minimum: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TopToolbar(
                    model: widget.model,
                    onImport: _chooseImport,
                    onOpenSettings: _openSettings,
                  ),
                ],
              ),
            ),
          ),
          // One non-overlapping vertical column at the bottom: the action
          // stack (locate / record / pause / stop) on top, then the selection
          // bar while an aggregate is selected, then the recording chip and
          // headline speed while a session runs, ending at the bottom edge.
          // One column, so none of them can overlap on narrow screens.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              minimum: const EdgeInsets.only(bottom: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The action stack (locate / record / pause / stop) at the
                  // top of the bottom column (see `BottomActionStack`; its
                  // record slot only shows once a real fix has arrived), so
                  // the bars below it end at the bottom edge of the map.
                  if (widget.locationSupported)
                    SizedBox(
                      width: double.infinity,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: BottomActionStack(
                            model: widget.model,
                            locating: _locating,
                            gpsWorking: _gpsWorking,
                            onLocate: _locate,
                          ),
                        ),
                      ),
                    ),
                  // The aggregate selection's actions pill: hide, color,
                  // fit, dismiss — a temporary state at the bottom of the
                  // map, above the recording chip and the action stack.
                  if (widget.model.selectedAnchor != null) ...[
                    SelectionBar(
                      model: widget.model,
                      onFit: () {
                        final selected = widget.model.selectedAggregate;
                        if (selected == null) return;
                        _fitWhenSized(
                          CameraFit.coordinates(
                            coordinates: selected.points,
                            padding: _fitPadding,
                          ),
                        );
                      },
                      onDismiss: () =>
                          setState(() => widget.model.selectedAnchor = null),
                    ),
                    const SizedBox(height: 4),
                  ],
                  // The recording dashboard: HUD chip and stats panel in
                  // the column, with its own per-fix listeners — a 1 Hz fix
                  // rebuilds the dashboard only.
                  RecordingDashboard(
                    key: _dashboardKey,
                    model: widget.model,
                    mapController: _mapController,
                  ),
                  // The dashboard's primary readout: the live speed, just
                  // under the chip while a session runs.
                  RecordingSpeedReadout(model: widget.model),
                ],
              ),
            ),
          ),
          // The empty-state hint only for a genuinely empty, idle map:
          // while a session records (even with nothing plotted yet) and
          // while the catalog has tracks — selected or not — it would
          // just sit on top of the dashboard or lie about the catalog.
          if (widget.model.tracks.isEmpty && !widget.model.isRecording)
            Center(child: EmptyHint(strings: strings)),
          if (widget.model.busy)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
