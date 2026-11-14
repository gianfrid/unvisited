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
import '../tile_source.dart';
import 'app_model.dart';
import 'fog_of_war.dart';
import 'format.dart';
import 'map_actions.dart';
import 'settings_sheet.dart';
import 'stats_panel.dart';
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

/// The angle equivalent to [course] (mod 360) closest to [reference] —
/// the camera rotation the course is applied against — so a course
/// crossing the 0/360 boundary rotates through the short arc, never the
/// long way around.
double nearestEquivalentRotation(double course, double reference) =>
    course + 360 * ((reference - course) / 360).roundToDouble();

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

  /// Hysteresis for the course-up camera rotation: only rotate the
  /// camera when the course delta vs its current rotation reaches this
  /// many degrees; below, leave the rotation untouched.
  static const double courseDeltaThreshold = 1.0;

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
    // The 1 Hz per-fix channel: only the live subtrees below listen to
    // it — the fog overlay and toolbar rebuild on model changes only.
    widget.model.recordingLive.addListener(_onRecordingFix);
    // Cross a zoom level: the fog coarseness is keyed to the zoom, so the
    // overlay must be rebuilt when the view moves between zoom levels
    // (the cell grid doubles per band — see fogCellSizeFor).
    _mapEvents = _mapController.mapEventStream.listen((event) {
      final cell = fogCellSizeFor(
        zoom: event.camera.zoom,
        latitude: event.camera.center.latitude,
      );
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
      _toast(AppStrings.ofContext(context).salvagedRecording(names.join(', ')));
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
    _fixRetryTimer = Timer.periodic(
      _fixRetryInterval,
      (_) => _silentPositionUpdate(),
    );
  }

  /// Whether the map follows the recording fixes (the dashboard's
  /// follow-camera): a new session arms it, a user pan releases it —
  /// a fix must never pull the view back against the user's hand.
  bool _followRecording = false;
  bool _wasRecording = false;

  /// The fit-request epoch MapPage handled last (see the import epoch):
  /// a track-tile tap asks for a fit to its aggregate.
  int _seenFitRequestEpoch = 0;

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
    widget.model.recordingLive.removeListener(_onRecordingFix);
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
    setState(() {});
  }

  /// The follow-camera rides each accepted fix while it is armed; the
  /// marker, HUD and trace rebuild off the session's own getters. No
  /// setState: fixes arrive at 1 Hz, so the live subtrees rebuild through
  /// the recording-live Listenable and the rest of the map stays still.
  void _onRecordingFix() {
    if (!mounted) return;
    if (!widget.model.isRecording || !_followRecording) return;
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return;
    // Course-up: while the follow holds, the camera rotates to the
    // current course so where the user is going stays ahead of them —
    // course-up makes the motion read upward on screen. The rotation
    // emits controller events (programmatic sources), so this never
    // releases the follow; any hand gesture still does, and with it
    // the rotation. nearestEquivalentRotation keeps the short arc
    // where the course crosses 0/360. The rotation is gated on the
    // device's *reported* heading, not the bridged course: a
    // magnetometer-less or bearing-only fix stream keeps the camera
    // north-up (the marker still rotates with the course), because a
    // bearing between fixes says where the user was, not where they
    // face. No heading yet — a first fix — leaves the camera
    // rotation alone.
    final heading = session?.currentHeading;
    if (heading == null) {
      _mapController.move(LatLng(lat, lon), _mapController.camera.zoom);
    } else {
      // With a reported heading, currentCourse is that same heading.
      final courseDelta = nearestEquivalentRotation(
            heading,
            _mapController.camera.rotation,
          ) -
          _mapController.camera.rotation;
      if (courseDelta.abs() >= courseDeltaThreshold) {
        _mapController.moveAndRotate(
          LatLng(lat, lon),
          _mapController.camera.zoom,
          nearestEquivalentRotation(heading, _mapController.camera.rotation),
        );
      } else {
        _mapController.move(LatLng(lat, lon), _mapController.camera.zoom);
      }
    }
  }

  /// Tap tolerance for aggregate selection: ~24 screen px worth of meters
  /// at the tap's zoom.
  double _hitToleranceMeters(LatLng tap) {
    final zoom = _mapController.camera.zoom;
    const metersPerPixelAtEquatorZoom0 = 156543.03392;
    return 24 *
        metersPerPixelAtEquatorZoom0 *
        math.cos(tap.latitude * math.pi / 180) /
        math.pow(2, zoom);
  }

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
    final highlight = tint.withValues(
      alpha: (tint.a + 0.55).clamp(0.0, 1.0),
    );
    return [
      for (final c in unlockCenters(
        selected.points,
        cellSizeMeters: _fogCellSize,
      ))
        CircleMarker(point: c, color: highlight, radius: unlockRadiusForCell(_fogCellSize), useRadiusInMeter: true),
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

  /// Stop: asks what to call the track first (the dialog defaults to the
  /// current date-time timestamp) and only finalizes on confirm — a
  /// cancelled dialog leaves the session recording.
  Future<void> _stopRecording() async {
    final strings = AppStrings.ofContext(context);
    final defaultName = widget.model.recordingName(DateTime.now());
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: defaultName);
        return AlertDialog(
          title: Text(strings.stopRecordingTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: strings.recordingNameLabel),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                controller.text.trim().isEmpty
                    ? defaultName
                    : controller.text.trim(),
              ),
              child: Text(strings.stopLabel),
            ),
          ],
        );
      },
    );
    if (!mounted || name == null) return; // Cancelled: keep recording.
    await widget.model.stopRecording(name: name);
  }

  /// While recording, the dashboard: the HUD chip — the pulsing dot with
  /// its live duration and distance, tap to expand — and the stats panel
  /// it opens, both re-rendering off the recording-live per-fix channel
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
                onTap: () => setState(() => _dashboardOpen = !_dashboardOpen),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.fiber_manual_record,
                        size: 12,
                        color: Colors.redAccent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatDuration(session.elapsed),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (meters > 0) ...[
                        const SizedBox(width: 12),
                        Text(
                          formatDistance(meters),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
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
                        _dashboardOpen ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: Theme.of(context).hintColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_dashboardOpen) StatsPanel(session: session, strings: strings),
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Text(
              speed == null ? '—' : '${(speed * 3.6).toStringAsFixed(1)} km/h',
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
                angle:
                    ((session!.currentCourse ?? 0) -
                        _mapController.camera.rotation) *
                    math.pi /
                    180,
                child: Icon(
                  Icons.navigation,
                  size: 32,
                  color: Theme.of(context).colorScheme.primary,
                  shadows: const [
                    Shadow(blurRadius: 4, color: Colors.black38)
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// The bar shown while an aggregate is selected: hide / color / fit,
  /// in a compact card so it reads as a temporary state, not a toolbar.
  Widget _selectionBar(AppStrings strings) {
    return Card(
      key: const ValueKey('selection-bar'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('selection-hide'),
              tooltip: strings.selectionHideTooltip,
              icon: const Icon(Icons.visibility_off),
              onPressed: () async {
                await widget.model.hideSelectedAggregate();
              },
            ),
            PopupMenuButton<String>(
              key: const ValueKey('selection-color'),
              tooltip: strings.selectionColorTooltip,
              icon: const Icon(Icons.palette_outlined),
              onSelected: (key) => widget.model.setAggregateColor(key),
              itemBuilder: (context) => [
                for (final entry in explorationTints.entries)
                  PopupMenuItem(
                    value: entry.key,
                    child: Row(
                      children: [
                        Icon(Icons.circle, color: entry.value, size: 18),
                        const SizedBox(width: 8),
                        Text(AppStrings.ofContext(context).tintName(entry.key)),
                      ],
                    ),
                  ),
              ],
            ),
            IconButton(
              key: const ValueKey('selection-fit'),
              tooltip: strings.fitTooltip,
              icon: const Icon(Icons.zoom_out_map),
              onPressed: () {
                final selected = widget.model.selectedAggregate;
                if (selected == null || selected.points.isEmpty) return;
                _fitWhenSized(
                  CameraFit.coordinates(
                    coordinates: selected.points,
                    padding: _fitPadding,
                  ),
                );
              },
            ),
            IconButton(
              key: const ValueKey('selection-dismiss'),
              tooltip: strings.selectionDismissTooltip,
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                widget.model.selectedAnchor = null;
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// Centers the map on the last saved position while waiting for a live  /// fix (and moves onto the fix once it arrives). Never asks for
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
        setState(() => _followRecording = true);
        _mapController.move(LatLng(lat, lon), _mapController.camera.zoom);
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
      setState(() {
        _locatedPosition = pos;
        // The attempt landed while a session runs: its fix is the one to
        // follow — arm the follow so the next fix takes the camera over.
        if (widget.model.isRecording) _followRecording = true;
      });
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

  void _toast(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Fog-of-war overlay: one translucent circle per unlocked grid cell, in
  /// the single exploration tint. Track polylines are gone by design — the
  /// union of circles is how a visited area shows on the map.
  List<CircleMarker> _buildFogCircles(List<MapTrack> tracks) {
    final tintKeys = widget.model.aggregateTintKeys;
    final out = <CircleMarker>[];
    final radius = unlockRadiusForCell(_fogCellSize);
    for (final a in widget.model.aggregates) {
      final key = '${[for (final t in a.members) t.id].join('|')}@$_fogCellSize';
      var centers = _fogCentersByAnchor[key];
      if (centers == null) {
        centers = unlockCenters(a.points, cellSizeMeters: _fogCellSize);
        _fogCentersByAnchor[key] = centers;
      }
      final tint =
          exploredAreaColor(tintKeys[a.anchorId] ?? defaultTintKey);
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
                    polylines: [
                      for (final seg in widget.model.recording!.liveSegments)
                        if (seg.length >= 2)
                          Polyline(
                            points: seg,
                            color: recordingTraceColor(
                                widget.model.recordingTint),
                            strokeWidth: 4,
                          ),
                    ],
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
                child: FloatingToolbar(
                  children: [
                    // Import and Fit fight the record-mode dashboard for
                    // space and attention; while a session runs the header
                    // keeps Tracks and Settings only. Locate and Record live
                    // in the bottom-left action stack below.
                    if (!widget.model.isRecording)
                      HeaderAction(
                        icon: const Icon(Icons.add),
                        label: strings.importLabel,
                        tooltip: strings.importTooltip,
                        onTap: _chooseImport,
                      ),
                    Builder(
                      builder: (context) => HeaderAction(
                        icon: const BadgeIcon(),
                        label: strings.tracksLabel,
                        tooltip: strings.tracksLabel,
                        onTap: () => Scaffold.of(context).openEndDrawer(),
                      ),
                    ),
                    HeaderAction(
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
          // Bottom-left action stack: the locate button hugs the map's
          // bottom-left corner and the record slot sits directly above it.
          // The record slot is hidden where the platform cannot deliver a
          // position (no host plugin, desktop Linux) or none has actually
          // arrived yet (GPS off at startup — the silent retry loop picks
          // the button up once a fix exists) — a session could never start
          // there. While a session runs the slot holds Pause; once paused
          // the slot reads Resume and a Stop action appears before it,
          // asking the track's name before it finalizes. The chip below
          // the toolbar still shows the live stats. Locate stays usable
          // during a session — its tap is the way back to the follow
          // after panning away (see
          // [_locate]'s session branch).
          if (widget.locationSupported)
            Positioned(
              left: 12,
              bottom: 0,
              child: SafeArea(
                minimum: const EdgeInsets.only(bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.model.recording?.state == RecordingState.paused)
                      HeaderAction(
                        icon: const Icon(Icons.stop),
                        label: strings.stopLabel,
                        tooltip: strings.stopLabel,
                        onTap: _stopRecording,
                      ),
                    if (_gpsWorking || widget.model.isRecording)
                      HeaderAction(
                        icon: Icon(
                          widget.model.isRecording
                              ? (widget.model.recording?.state ==
                                        RecordingState.paused
                                    ? Icons.play_arrow
                                    : Icons.pause)
                              : Icons.fiber_manual_record,
                        ),
                        label: widget.model.isRecording
                            ? (widget.model.recording?.state ==
                                      RecordingState.paused
                                  ? strings.resumeLabel
                                  : strings.pauseLabel)
                            : strings.recordLabel,
                        tooltip: widget.model.isRecording
                            ? (widget.model.recording?.state ==
                                      RecordingState.paused
                                  ? strings.resumeLabel
                                  : strings.pauseLabel)
                            : strings.recordLabel,
                        onTap: widget.model.isRecording
                            ? (widget.model.recording?.state ==
                                      RecordingState.paused
                                  ? widget.model.resumeRecording
                                  : widget.model.pauseRecording)
                            : _startRecording,
                      ),
                    HeaderAction(
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
                  ],
                ),
              ),
            ),
          // The selection bar: while an aggregate is selected it offers
          // hide (deselect = member tracks' visible=false), a color
          // override (persisted under the anchor id) and fit to selection.
          if (widget.model.selectedAnchor != null)
            Positioned(
              left: 120,
              right: 120,
              bottom: 0,
              child: SafeArea(
                minimum: const EdgeInsets.only(bottom: 16),
                child: _selectionBar(strings),
              ),
            ),
          // The HUD chip and stats panel rebuild per fix through the
          // recording-live channel; the chip's tap-to-open toggles the
          // panel through the model-wide setState, which rebuilds this
          // builder too.
          ListenableBuilder(
            listenable: widget.model.recordingLive,
            builder: (context, _) => _recordingDashboard(strings),
          ),
          _recordingSpeed(),
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
