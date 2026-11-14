import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../host_channel.dart';
import '../l10n/app_strings.dart';
import '../recording/recording_session.dart';
import '../storage/track_store.dart';
import '../tile_source.dart';
import '../build_version.dart';
import 'app_model.dart';
import 'fog_of_war.dart';
import 'track_colors.dart';

class MapPage extends StatefulWidget {
  const MapPage(
      {super.key,
      required this.model,
      required this.cacheDir,
      this.versionFuture,
      this.locationSupported = false});

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

/// Compact distance: meters under the kilometer, then km with the last
/// digit dropped past double digits. The one format every shown distance
/// uses (the recording chip and stats panel, the tracks drawer).
String _formatDistance(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} km'
    : '${meters.round()} m';

/// Clock-like duration: h:mm:ss past the hour, mm:ss otherwise. The one
/// format every recording duration uses (the chip, the stats panel).
String _formatDuration(Duration d) => d.inHours > 0
    ? '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
        '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}'
    : '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
        '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

/// The angle equivalent to [course] (mod 360) closest to [reference] —
/// the camera rotation the course is applied against — so a course
/// crossing the 0/360 boundary rotates through the short arc, never the
/// long way around.
double nearestEquivalentRotation(double course, double reference) =>
    course + 360 * ((reference - course) / 360).roundToDouble();

/// OSM standard tiles exist between zoom 0 and 19; 3 is a world view that
/// still feels like a map. Both the camera and the zoom slider stay inside.
const _minZoom = 3.0;
const _maxZoom = 19.0;

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
          zoom: event.camera.zoom, latitude: event.camera.center.latitude);
      // The follow-camera releases on any gesture move — including the
      // fling/double-tap-zoom animations that report through their own
      // sources after the gesture ends.
      var dirty = cell != _fogCellSize;
      if (_followRecording && !_programmaticEvents.contains(event.source)) {
        _followRecording = false;
        dirty = true;
      }
      if (!dirty && _locatedPosition != null) {
        // The position marker shows the last fix; once the user pans away
        // from it, it would sit somewhere they are not — drop it.
        final drift = const Distance().distance(
            event.camera.center, _locatedPosition!);
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
    _announceSalvagedRecordings();
  }

  /// The startup salvage notice: a killed session's staged recording was
  /// imported during [AppModel.load]; one toast says so. Read once at
  /// initState — the names are cleared by nothing, the toast is not
  /// re-shown on later rebuilds.
  void _announceSalvagedRecordings() {
    final names = widget.model.salvagedRecordingNames;
    if (names.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _toast(AppStrings.ofContext(context)
          .salvagedRecording(names.join(', ')));
    });
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
    _fixRetryTimer =
        Timer.periodic(_fixRetryInterval, (_) => _silentPositionUpdate());
  }

  /// Whether the map follows the recording fixes (the dashboard's
  /// follow-camera): a new session arms it, a user pan releases it —
  /// a fix must never pull the view back against the user's hand.
  bool _followRecording = false;
  bool _wasRecording = false;

  /// Whether the recording dashboard's stats panel is expanded; the
  /// HUD chip toggles it.
  bool _dashboardOpen = false;

  /// The recording's screen latch: the session keeps the screen on so the
  /// dashboard stays readable on a bike or in a pocket-free hand. The
  /// latch is a per-session default-on that the chip's screen-lock icon
  /// toggles; the flag itself lives on the Android window (see the host
  /// channel's `keepScreenOn`), so it dies with the window — no stale
  /// latch survives a session's end even on a process kill.
  bool _screenLockOff = false;
  bool _screenOn = false;

  /// Applies the latch if it changed. Best effort: a platform without the
  /// host channel (desktop, tests) has no window to latch; its OS timeout
  /// applies.
  Future<void> _applyScreenOn() async {
    final on = widget.model.isRecording && !_screenLockOff;
    if (on == _screenOn) return;
    _screenOn = on;
    try {
      await hostChannel.invokeMethod('keepScreenOn', on);
    } on MissingPluginException {
      // No host side (desktop, tests): nothing to latch.
    } on PlatformException {
      // The host refused (a headless window?): the OS timeout applies.
    }
  }

  /// Map-event sources that are not the user's hand: programmatic moves
  /// (the follow-camera itself, the zoom slider), camera fits, customs.
  /// Everything else runs the follow-camera release below.
  static const _programmaticEvents = <MapEventSource>{
    MapEventSource.mapController,
    MapEventSource.fitCamera,
    MapEventSource.custom,
  };

  /// Cached unlock centers keyed to the current overlay inputs (visible
  /// track ids + cell size), so pans and transient item rebuilds do not
  /// re-walk every track point.
  String? _fogCentersKey;
  List<LatLng> _fogCenters = const [];

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
        _fitWhenSized(CameraFit.coordinates(
          coordinates: pts,
          padding: _fitPadding,
        ));
      }
    }
    // A session boundary re-arms the follow-camera (the old marker and
    // any open panel are gone with it) and resets the screen latch's
    // opt-out: a new session keeps the screen on again.
    final recording = widget.model.isRecording;
    if (recording != _wasRecording) {
      _wasRecording = recording;
      _followRecording = recording;
      _dashboardOpen = false;
      _screenLockOff = false;
    }
    // Applied best-effort from here and from the chip's toggle: the
    // window flag matters only while the dashboard is in front anyway.
    _applyScreenOn();
    // The follow-camera rides each accepted fix while it is armed; the
    // marker rebuilds off the session's own getters below either way.
    if (recording && _followRecording) {
      final session = widget.model.recording;
      final lat = session?.currentLat;
      final lon = session?.currentLon;
      if (lat != null && lon != null) {
        // Course-up: while the follow holds, the camera rotates to the
        // current course so where the user is going stays ahead of them —
        // course-up makes the motion read upward on screen. The rotation
        // emits controller events (programmatic sources), so this never
        // releases the follow; any hand gesture still does, and with it
        // the rotation. nearestEquivalentRotation keeps the short arc
        // where the course crosses 0/360. No course yet — a first fix
        // without heading — leaves the camera rotation alone.
        final course = session?.currentCourse;
        if (course == null) {
          _mapController.move(
              LatLng(lat, lon), _mapController.camera.zoom);
        } else {
          _mapController.moveAndRotate(
              LatLng(lat, lon),
              _mapController.camera.zoom,
              nearestEquivalentRotation(
                  course, _mapController.camera.rotation));
        }
      }
    }
    setState(() {});
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

  void _fitTracks() {
    final pts = widget.model.allVisiblePoints;
    if (pts.isEmpty) return;
    _fitWhenSized(
        CameraFit.coordinates(coordinates: pts, padding: _fitPadding));
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

  /// Record button: starts a session through the model and pulses the
  /// chip; a declined permission says so instead of leaving a button that
  /// silently did nothing. Alongside it, the one soft POST_NOTIFICATIONS
  /// ask fires unawaited — a refusal leaves the session mute, and the
  /// once-per-run guard keeps repeated taps from nagging.
  bool _notificationsAsked = false;

  Future<void> _startRecording() async {
    final strings = AppStrings.ofContext(context);
    if (!_notificationsAsked) {
      _notificationsAsked = true;
      unawaited(widget.model.requestPostNotifications());
    }
    final staged = await widget.model.startRecording();
    if (!mounted || staged != null) return;
    _toast(strings.recordDeclined);
  }

  Future<void> _stopRecording() => widget.model.stopRecording();

  /// While recording, the dashboard: the HUD chip — the pulsing dot with
  /// its live duration and distance, tap to expand — and the stats panel
  /// it opens, both re-rendering off the model's per-fix notifications
  /// (the engine's numbers, not a straight-line snapshot). Absent while
  /// no session runs.
  Widget _recordingDashboard(AppStrings strings) {
    final session = widget.model.recording;
    if (session == null) return const SizedBox.shrink();
    final meters = session.distanceMeters;
    return Positioned(
      top: kToolbarHeight + 16,
      left: 12,
      right: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            child: Card(
              child: InkWell(
                key: const ValueKey('recording-chip'),
                borderRadius: BorderRadius.circular(12),
                onTap: () =>
                    setState(() => _dashboardOpen = !_dashboardOpen),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fiber_manual_record,
                          size: 12, color: Colors.redAccent),
                      const SizedBox(width: 8),
                      Text(_formatDuration(session.elapsed),
                          style:
                              Theme.of(context).textTheme.bodyMedium),
                      if (meters > 0) ...[
                        const SizedBox(width: 12),
                        Text(_formatDistance(meters),
                            style:
                                Theme.of(context).textTheme.bodyMedium),
                      ],
                      const SizedBox(width: 8),
                      // The screen latch's toggle: lit while the screen
                      // stays on, dimmed while it may sleep (see the
                      // state notes on the latch). The chip only exists
                      // while a session runs, so does the toggle.
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.screen_lock_portrait,
                          size: 16,
                          color: _screenLockOff
                              ? Theme.of(context).hintColor
                              : Theme.of(context).colorScheme.primary,
                        ),
                        tooltip: _screenLockOff
                            ? strings.screenMayTurnOff
                            : strings.screenStaysOn,
                        onPressed: () {
                          setState(() => _screenLockOff = !_screenLockOff);
                          _applyScreenOn();
                        },
                      ),
                      Icon(
                        _dashboardOpen
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: Theme.of(context).hintColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_dashboardOpen)
            _StatsPanel(session: session, strings: strings),
        ],
      ),
    );
  }

  /// The dashboard's primary readout: the live speed, big and
  /// bottom-center — the stem display a bike computer shows the rider.
  /// Absent while no session runs; before the first fix and while paused
  /// (paused sessions are silent) it shows a dash, like the stats panel's
  /// not-yet-measured values.
  Widget _recordingSpeed() {
    final session = widget.model.recording;
    if (session == null) return const SizedBox.shrink();
    final speed = session.currentSpeed;
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: Card(
          key: const ValueKey('recording-speed'),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Text(
              speed == null
                  ? '—'
                  : '${(speed * 3.6).toStringAsFixed(1)} km/h',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
      ),
    );
  }

  /// The recording marker: at the last accepted fix, rotating to the
  /// course relative to the camera's rotation, so the nose points along
  /// the course on screen — straight up while the follow-camera holds the
  /// camera on the course (these are not two settings: the rotation *is*
  /// the follow; any gesture releases both; see SPEC). A fix without a
  /// heading and no bearing yet renders unrotated.
  List<Widget> _recordingMarkers() {
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return const [];
    return [
      MarkerLayer(
        markers: [
          Marker(
            point: LatLng(lat, lon),
            width: 44,
            height: 44,
            child: Transform.rotate(
              key: const ValueKey('recording-marker-rotate'),
              angle: ((session!.currentCourse ?? 0) -
                      _mapController.camera.rotation) *
                  math.pi /
                  180,
              child: Icon(
                Icons.navigation,
                size: 32,
                color: Theme.of(context).colorScheme.primary,
                shadows: const [
                  Shadow(blurRadius: 4, color: Colors.black38),
                ],
              ),
            ),
          ),
        ],
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
  /// The whole attempt is bracketed by [_locating], so the toolbar button
  /// turns into a spinner for as long as the fix takes. Re-entrant taps
  /// are ignored: a second GPS request would not answer any sooner.
  Future<void> _locate() async {
    if (_locating) return;
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
      setState(() => _locatedPosition = pos);
      // A deliberated locate is also evidence the GPS works: it opens the
      // Record button, no silent retry needed.
      _gpsWorking = true;
      _fixRetryTimer?.cancel();
      // Never zoom out: a user already closer than the locate zoom keeps
      // their detail level.
      final zoom = _mapController.camera.zoom < _locateZoom
          ? _locateZoom
          : _mapController.camera.zoom;
      _mapController.move(pos, zoom);
    } finally {
      // Also runs when the widget went away mid-flight; the mounted check
      // keeps setState off a disposed element.
      if (mounted) setState(() => _locating = false);
    }
  }

  static String _locateFailureMessage(
      AppStrings strings, LocationFailure? failure) {
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
      builder: (context) => _SettingsSheet(
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

  void _toast(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Fog-of-war overlay: one translucent circle per unlocked grid cell, in
  /// the single exploration tint. Track polylines are gone by design — the
  /// union of circles is how a visited area shows on the map.
  List<CircleMarker> _buildFogCircles(List<MapTrack> tracks) {
    final key =
        '${[for (final t in tracks) t.meta.id].join('|')}@$_fogCellSize';
    if (key != _fogCentersKey) {
      _fogCentersKey = key;
      _fogCenters = unlockCenters(
        tracks.expand((t) => t.points),
        cellSizeMeters: _fogCellSize,
      );
    }
    final radius = unlockRadiusForCell(_fogCellSize);
    final tint = exploredAreaColor(widget.model.trackTint);
    return [
      for (final c in _fogCenters)
        CircleMarker(
          point: c,
          color: tint,
          radius: radius,
          useRadiusInMeter: true,
        ),
    ];
  }

  /// Unlocked road corridors: the matched sub-polylines persisted on each
  /// visible track, drawn fat and translucent in the same tint family so
  /// corridors and circles read as one overlay. A way unlocked by several
  /// tracks draws once (the corridors usually coincide; double-drawing
  /// would double-darken the shared stretch). flutter_map culls off-screen
  /// polylines and simplifies them per zoom; LOD variants are deferred
  /// until catalog scale demands them.
  List<Polyline> _buildCorridors(List<MapTrack> tracks) {
    final tint = exploredAreaColor(widget.model.trackTint);
    final seen = <String>{};
    final out = <Polyline>[];
    for (final t in tracks) {
      t.meta.unlockedWays.forEach((wayId, corridors) {
        if (!seen.add(wayId)) return;
        for (final corridor in corridors) {
          if (corridor.length < 2) continue;
          out.add(Polyline(
            points: corridor,
            strokeWidth: 6,
            color: tint,
          ));
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
      endDrawer: TrackDrawer(
        model: widget.model,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              // Start at the last saved position (Berlin as the very first
              // run fallback); a live fix refines this after startup.
              initialCenter: widget.model.savedPosition ?? _berlinCenter,
              initialZoom: _startZoom,
              minZoom: _minZoom,
              maxZoom: _maxZoom,
              // Startup fit for saved tracks goes through the engine path:
              // flutter_map applies it only once the camera has a real
              // size, guarding against the zero-sized startup constraints
              // of a fresh window surface. A manual post-frame fitCamera
              // here degenerates the camera instead and the map stays
              // grey until the first pan.
              initialCameraFit: mapTracks.isEmpty
                  ? null
                  : CameraFit.coordinates(
                      coordinates: [
                        for (final t in mapTracks) ...t.points,
                      ],
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
              CircleLayer(
                circles: _buildFogCircles(mapTracks),
              ),
              // Unlocked road corridors (fog-of-war for streets), above
              // the circles so the corridor reads on top of the blobs.
              if (corridors.isNotEmpty) PolylineLayer(polylines: corridors),
              // The live recording trace: the session's accepted fixes as
              // polylines, translucent in a fixed recording red — outside
              // the catalog tint family, clearly in-progress. Above the
              // fog, below the course-up marker. Absent when no session
              // runs; after stop the finalized track is a catalog track.
              if (widget.model.recording != null)
                PolylineLayer(
                  polylines: [
                    for (final seg in widget.model.recording!.liveSegments)
                      if (seg.length >= 2)
                        Polyline(
                          points: seg,
                          color: Colors.redAccent.withValues(alpha: 0.65),
                          strokeWidth: 4,
                        ),
                  ],
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
                  bottom: 16),
              child: Center(child: _ZoomSlider(controller: _mapController)),
            ),
          ),
          // Compact floating toolbar, centered across the top instead of
          // a full-width app bar.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              minimum: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.topCenter,
                child: _FloatingToolbar(
                  children: [
                  // Import and Fit/Locate fight the record-mode dashboard
                  // for space and attention; while a session runs the
                  // header keeps the essential actions only (Stop, Pause,
                  // Tracks, Settings) and these come back after it.
                  if (!widget.model.isRecording)
                    _HeaderAction(
                      icon: const Icon(Icons.add),
                      label: strings.importLabel,
                      tooltip: strings.importTooltip,
                      onTap: _chooseImport,
                    ),
                  if (!widget.model.isRecording)
                    _HeaderAction(
                      icon: const Icon(Icons.zoom_out_map),
                      label: strings.fitLabel,
                      tooltip: strings.fitTooltip,
                      onTap: mapTracks.isEmpty ? null : _fitTracks,
                    ),
                  if (widget.locationSupported && !widget.model.isRecording)
                    _HeaderAction(
                      icon: _locating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location),
                      label: _locating ? strings.locating : strings.locateLabel,
                      tooltip: strings.locateTooltip,
                      onTap: _locating ? null : _locate,
                    ),
                  // Record: hidden where the platform cannot deliver a
                  // position (no host plugin, desktop Linux) or none has
                  // actually arrived yet (GPS off at startup — the silent
                  // retry loop picks the button up once a fix exists) — a
                  // session could never start there. While recording the
                  // same slot stops it; the chip below shows the live
                  // stats and a pause action sits beside it.
                  if (widget.locationSupported &&
                      (_gpsWorking || widget.model.isRecording))
                    _HeaderAction(
                      icon: Icon(widget.model.isRecording
                          ? Icons.stop
                          : Icons.fiber_manual_record),
                      label: widget.model.isRecording
                          ? strings.stopLabel
                          : strings.recordLabel,
                      tooltip: widget.model.isRecording
                          ? strings.stopLabel
                          : strings.recordLabel,
                      onTap: widget.model.isRecording
                          ? _stopRecording
                          : _startRecording,
                    ),
                  if (widget.model.isRecording)
                    _HeaderAction(
                      icon: Icon(widget.model.recording?.state ==
                              RecordingState.paused
                          ? Icons.play_arrow
                          : Icons.pause),
                      label: widget.model.recording?.state ==
                              RecordingState.paused
                          ? strings.resumeLabel
                          : strings.pauseLabel,
                      tooltip: widget.model.recording?.state ==
                              RecordingState.paused
                          ? strings.resumeLabel
                          : strings.pauseLabel,
                      onTap: widget.model.recording?.state ==
                              RecordingState.paused
                          ? widget.model.resumeRecording
                          : widget.model.pauseRecording,
                    ),
                  Builder(
                    builder: (context) => _HeaderAction(
                      icon: const _BadgeIcon(),
                      label: strings.tracksLabel,
                      tooltip: strings.tracksLabel,
                      onTap: () => Scaffold.of(context).openEndDrawer(),
                    ),
                  ),
                  _HeaderAction(
                    icon: const Icon(Icons.settings_outlined),
                    label: strings.settingsLabel,
                    tooltip: strings.settingsLabel,
                    onTap: _openSettings,
                  ),
                  ],
                ),
              ),
            ),
          ),
          _recordingDashboard(strings),
          _recordingSpeed(),
          // The empty-state hint only for a genuinely empty, idle map:
          // while a session records (even with nothing plotted yet) and
          // while the catalog has tracks — selected or not — it would
          // just sit on top of the dashboard or lie about the catalog.
          if (widget.model.tracks.isEmpty && !widget.model.isRecording)
            Center(
              child: _EmptyHint(strings: strings),
            ),
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

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.route, size: 40),
            const SizedBox(height: 8),
            Text(
              strings.noTracksYet,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                strings.noTracksHint,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BadgeIcon extends StatelessWidget {
  const _BadgeIcon();

  @override
  Widget build(BuildContext context) => const Icon(Icons.stacked_line_chart);
}

/// The header as a compact pill that hugs its content, floating above
/// the map at the top-right corner instead of a full-width bar.
class _FloatingToolbar extends StatelessWidget {
  const _FloatingToolbar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A header action that says what it does: icon over a short caption.
/// Tooltips stay for long-press/hover explanations; the caption alone
/// is meant to make them unnecessary.
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
  });

  final Widget icon;
  final String label;
  final String tooltip;

  /// Null disables the action (see the Fit button on an empty map).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final color = scheme.onSurface.withValues(alpha: enabled ? 1 : 0.38);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 48,
        height: kToolbarHeight,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme.merge(
                data: IconThemeData(size: 20, color: color),
                child: icon,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lateral zoom slider pinned to the map's left edge: step buttons at the
/// ends and a draggable rail whose thumb shows the live zoom level. It
/// tracks every camera change (wheel, pinch, keyboard R/F and double-tap),
/// not just its own input.
class _ZoomSlider extends StatefulWidget {
  const _ZoomSlider({required this.controller});

  final MapController controller;

  @override
  State<_ZoomSlider> createState() => _ZoomSliderState();
}

class _ZoomSliderState extends State<_ZoomSlider> {
  static const _trackExtent = 180.0;
  static const _thumbExtent = 28.0;

  StreamSubscription<MapEvent>? _events;
  double _zoom = _minZoom; // overwritten in initState from the camera

  @override
  void initState() {
    super.initState();
    _zoom = widget.controller.camera.zoom.clamp(_minZoom, _maxZoom);
    // Any camera move (pinch, wheel, fit) updates the thumb's position.
    _events = widget.controller.mapEventStream.listen((event) {
      final zoom = event.camera.zoom.clamp(_minZoom, _maxZoom);
      if (zoom != _zoom) setState(() => _zoom = zoom);
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _moveTo(double zoom) {
    final target = zoom.clamp(_minZoom, _maxZoom);
    if (target == _zoom) return;
    final camera = widget.controller.camera;
    widget.controller.move(camera.center, target);
  }

  void _dragTo(Offset localPosition) {
    // Top of the rail is max zoom; dragging up zooms in.
    final fraction =
        (1 - localPosition.dy / _trackExtent).clamp(0.0, 1.0);
    _moveTo(_minZoom + fraction * (_maxZoom - _minZoom));
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final scheme = Theme.of(context).colorScheme;
    final fraction = (_zoom - _minZoom) / (_maxZoom - _minZoom);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            blurRadius: 6,
            color: Colors.black26,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomStepButton(
            icon: Icons.add,
            tooltip: strings.zoomIn,
            onTap: () => _moveTo(_zoom + 1),
          ),
          SizedBox(
            key: const ValueKey('zoom-track'),
            width: 40,
            height: _trackExtent,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (details) =>
                  _dragTo(details.localPosition),
              onVerticalDragUpdate: (details) =>
                  _dragTo(details.localPosition),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Center(
                    child: Container(
                      width: 4,
                      height: _trackExtent - 8,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: fraction * (_trackExtent - _thumbExtent),
                    child: Container(
                      width: _thumbExtent,
                      height: _thumbExtent,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(blurRadius: 4, color: Colors.black38),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _ZoomStepButton(
            icon: Icons.remove,
            tooltip: strings.zoomOut,
            onTap: () => _moveTo(_zoom - 1),
          ),
        ],
      ),
    );
  }
}

class _ZoomStepButton extends StatelessWidget {
  const _ZoomStepButton(
      {required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 18),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }
}

/// Bottom sheet hosting all app settings: an About card (build date), the
/// map appearance controls and the destructive delete-all entry.
class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet(
      {required this.model,
      required this.trackCount,
      this.versionFuture});

  final AppModel model;
  final int trackCount;

  /// Build time shown in the About card; tests inject a fixed value so
  /// no git process is spawned from a widget test.
  final Future<String>? versionFuture;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                strings.settingsTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Unvisited',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(strings.aboutDescription),
                  const SizedBox(height: 8),
                  FutureBuilder<String>(
                    future: versionFuture ?? AppVersion.resolve(),
                    builder: (context, snapshot) => Text(
                      strings.buildDate(snapshot.data ?? '...'),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).hintColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // The appearance controls read the live model, so changes show on
          // the map behind the sheet immediately.
          AnimatedBuilder(
            animation: model,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  dense: true,
                  title: Text(strings.trackColor),
                  subtitle: Text(strings.trackColorSubtitle),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      for (final entry in explorationTints.entries)
                        _TintSwatch(
                          tintKey: entry.key,
                          color: entry.value,
                          selected: model.trackTint == entry.key,
                          onTap: () => model.setTrackTint(entry.key),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  dense: true,
                  title: Text(strings.zoomSlider),
                  subtitle: Text(strings.zoomSliderSubtitle),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                          value: 'left', label: Text(strings.left)),
                      ButtonSegment(
                          value: 'right', label: Text(strings.right)),
                    ],
                    selected: {model.zoomSliderSide},
                    onSelectionChanged: (selection) =>
                        model.setZoomSliderSide(selection.first),
                  ),
                ),
                ListTile(
                  dense: true,
                  title: Text(strings.mapLayer),
                  subtitle: Text(strings.mapLayerSubtitle),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                          value: 'standard',
                          label: Text(strings.standardLayer)),
                      ButtonSegment(
                          value: 'cycle', label: Text(strings.cycleLayer)),
                    ],
                    selected: {model.tileLayer},
                    onSelectionChanged: (selection) =>
                        model.setTileLayer(selection.first),
                  ),
                ),
                ListTile(
                  dense: true,
                  title: Text(strings.language),
                  subtitle: Text(strings.languageSubtitle),
                  trailing: Text(
                    model.language == 'system'
                        ? strings.systemLanguage
                        : strings.languageName(model.language),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  onTap: () => _pickLanguage(context, model),
                ),
                ListTile(
                  dense: true,
                  title: Text(strings.theme),
                  subtitle: Text(strings.themeSubtitle),
                  trailing: Text(
                    model.themeMode == 'system'
                        ? strings.systemTheme
                        : model.themeMode == 'light'
                            ? strings.lightTheme
                            : strings.darkTheme,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  onTap: () => _pickTheme(context, model),
                ),
                ListTile(
                  dense: true,
                  title: Text(strings.roadData),
                  subtitle: Text(strings.roadDataSubtitle),
                  trailing: Text(
                    model.roadsName ?? strings.roadDataNone,
                    overflow: TextOverflow.ellipsis,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  onTap: () => _pickRoadData(context, model),
                ),
                // Battery optimization: Android-only, and soft — the row
                // only reports the state and its tap opens the system
                // page; nothing blocks, nothing is requested for the app.
                // (Available only on Android because that is the only
                // platform the host channel answers on.)
                if (Platform.isAndroid)
                  FutureBuilder<bool?>(
                    future: model.batteryOptimizationExcluded(),
                    builder: (context, snapshot) => ListTile(
                      dense: true,
                      title: Text(strings.batteryOptimization),
                      subtitle: Text(snapshot.data == true
                          ? strings.batteryExcluded
                          : strings.batteryAdvisory),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 0),
                      onTap: () => model.openBatteryOptimizationSettings(),
                    ),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: Text(strings.deleteAllTracks),
            subtitle: Text(
              trackCount == 0
                  ? strings.noStoredTracks
                  : strings.storedCount(trackCount),
            ),
            enabled: trackCount > 0,
            onTap: () => Navigator.of(context).pop('deleteAll'),
          ),
          const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Language picker: "system" plus one entry per supported language.
///
/// A dialog rather than a DropdownButton so the choice is one tap on a
/// phone, and each language is named in itself ("Italiano", "English") -
/// someone who switched by accident can always find their way back even
/// if they cannot read the current UI language.
Future<void> _pickLanguage(BuildContext context, AppModel model) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      final strings = AppStrings.ofContext(context);
      return SimpleDialog(
        title: Text(strings.language),
        children: [
          RadioGroup<String>(
            groupValue: model.language,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  value: 'system',
                  title: Text(strings.systemLanguage),
                ),
                for (final locale in AppStrings.supportedLocales)
                  RadioListTile<String>(
                    value: locale.languageCode,
                    title: Text(strings.languageName(locale.languageCode)),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
  if (choice != null) await model.setLanguage(choice);
}

/// Theme picker: "system", "light", or "dark".
Future<void> _pickTheme(BuildContext context, AppModel model) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      final strings = AppStrings.ofContext(context);
      return SimpleDialog(
        title: Text(strings.theme),
        children: [
          RadioGroup<String>(
            groupValue: model.themeMode,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RadioListTile<String>(
                  value: 'system',
                  title: Text(strings.systemTheme),
                ),
                RadioListTile<String>(
                  value: 'light',
                  title: Text(strings.lightTheme),
                ),
                RadioListTile<String>(
                  value: 'dark',
                  title: Text(strings.darkTheme),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  if (choice != null) await model.setThemeMode(choice);
}

/// Road-data picker: choose a side-loaded `.unvisited-roads` region file
/// or remove the current one. "Choose" opens the system file picker; the
/// region format, like track formats, is decided by content, so no
/// extension filter. Activation (and the unlock-state recompute a swap
/// triggers) runs on the model; the usual busy flag covers the wait.
Future<void> _pickRoadData(BuildContext context, AppModel model) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) {
      final strings = AppStrings.ofContext(context);
      return SimpleDialog(
        title: Text(strings.roadData),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('choose'),
            child: Text(strings.roadDataChoose),
          ),
          if (model.roadsName != null)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop('remove'),
              child: Text(strings.roadDataRemove),
            ),
        ],
      );
    },
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'remove') {
    await model.removeRoadFile();
    return;
  }
  final failure = await model.pickRoadFile();
  if (failure != null && context.mounted) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppStrings.ofContext(context).roadDataInvalid)),
    );
  }
}

/// One selectable tint swatch for the exploration overlay, labeled by
/// its tooltip; the selection ring marks the persisted tint.
class _TintSwatch extends StatelessWidget {
  const _TintSwatch({
    required this.tintKey,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String tintKey;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = AppStrings.ofContext(context).tintName(tintKey);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: name,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: ShapeDecoration(
              shape: CircleBorder(
                side: BorderSide(
                  width: 2,
                  color: selected ? scheme.primary : Colors.transparent,
                ),
              ),
            ),
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  // The overlay tint is translucent by design; the swatch
                  // shows the solid color it is made from.
                  color: color.withValues(alpha: 1),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The recording dashboard's stats panel: the engine's live numbers as
/// labeled rows in the card under the HUD chip. The labels come from
/// [strings]; the values carry their units code-side like the distances
/// do, and a not-yet-measured value shows a dash.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel({required this.session, required this.strings});

  final RecordingSession session;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    String kmh(double? metersPerSecond) => metersPerSecond == null
        ? '—'
        : '${(metersPerSecond * 3.6).toStringAsFixed(1)} km/h';
    final moving = session.movingTime;
    final avg =
        moving.inSeconds > 0 ? session.distanceMeters / moving.inSeconds : null;
    final rows = <(String, String)>[
      // The live speed is the primary readout — the big one below the
      // map's top chip (see _recordingSpeed) — not a panel row.
      (strings.statAvgSpeed, kmh(avg)),
      (
        strings.statDistance,
        session.distanceMeters > 0
            ? _formatDistance(session.distanceMeters)
            : '—',
      ),
      (strings.statElapsed, _formatDuration(session.elapsed)),
      (strings.statMoving, _formatDuration(moving)),
      if (session.currentEle != null)
        (strings.statAltitude, '${session.currentEle!.round()} m'),
    ];
    return Card(
      key: const ValueKey('stats-panel'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    const SizedBox(width: 16),
                    Text(value, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              ),
          const SizedBox(height: 4),
        ],
        ),
      ),
    );
  }
}

class TrackDrawer extends StatelessWidget {
  const TrackDrawer({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    // Display order: most recent first (startTimeUtc descending,
    // timestamp-less tracks last), original catalog position breaking
    // ties so same-start tracks keep their import order.
    final orderedTracks =
        [for (var i = 0; i < model.tracks.length; i++) (i, model.tracks[i])];
    orderedTracks.sort((a, b) {
      final aStart = a.$2.startTimeUtc;
      final bStart = b.$2.startTimeUtc;
      if (aStart == null && bStart == null) return a.$1.compareTo(b.$1);
      if (aStart == null) return 1;
      if (bStart == null) return -1;
      final byTime = bStart.compareTo(aStart);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return Drawer(
      width: 360,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    strings.tracksLabel,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  Text(
                    '${model.tracks.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  IconButton(
                    tooltip: model.allTracksVisible
                        ? strings.deselectAllTracks
                        : strings.selectAllTracks,
                    icon: Icon(model.allTracksVisible
                        ? Icons.deselect
                        : Icons.done_all),
                    onPressed: model.tracks.isEmpty
                        ? null
                        : () =>
                            model.setAllVisible(!model.allTracksVisible),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: model.tracks.isEmpty
                  ? Center(child: Text(strings.nothingImportedYet))
                  : ListView.builder(
                      // Most recent first: startTimeUtc descending,
                      // timestamp-less tracks last. The original catalog
                      // position breaks ties — List.sort gives no
                      // stability guarantee, and same-start tracks must
                      // keep their import order. Display order only; the
                      // catalog and the index stay as imported.
                      itemCount: orderedTracks.length,
                      itemBuilder: (context, i) {
                        final t = orderedTracks[i].$2;
                        return _TrackTile(
                          model: model,
                          track: t,
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.model, required this.track});

  final AppModel model;
  final StoredTrack track;

  /// The confirmation both destructive entry points (swipe and button)
  /// share: one accidental gesture must not destroy the track. A cancel
  /// or bar dismissal is a no-op; the drawer stays open and the list
  /// updates the moment the delete lands. Returns whether the user
  /// confirmed — [Dismissible.confirmDismiss] consumes the same signal.
  Future<bool> _confirmDelete(
      BuildContext context, AppStrings strings) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(strings.deleteConfirmTitle(track.name)),
            content: Text(strings.deleteConfirmBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(strings.deleteConfirmCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(strings.deleteConfirmGo),
              ),
            ],
          ),
        ) ==
        true;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final distance = _formatDistance(track.distanceMeters);
    final duration = track.durationSeconds == null
        ? '—'
        : _formatDuration(Duration(seconds: track.durationSeconds!.round()));
    return Dismissible(
      key: ValueKey('track-${track.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      // The swipe only dismisses after a confirmation; a declined dialog
      // leaves the tile in place and nothing deleted.
      confirmDismiss: (_) => _confirmDelete(context, strings),
      onDismissed: (_) => model.delete(track),
      child: CheckboxListTile(
        value: track.visible,
        onChanged: (_) => model.toggleVisible(track),
        title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${track.format} · ${strings.pointCount(track.pointCount)} · '
          '$distance · $duration',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // Discoverable next to the swipe-to-delete on touch devices;
        // there is no swipe equivalent with a mouse on the desktop.
        secondary: IconButton(
          tooltip: strings.deleteTrack,
          icon: const Icon(Icons.delete_outline),
          visualDensity: VisualDensity.compact,
          onPressed: () async {
            if (await _confirmDelete(context, strings)) await model.delete(track);
          },
        ),
        dense: true,
      ),
    );
  }
}
