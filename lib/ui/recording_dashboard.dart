import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../debug_log.dart';
import '../host_channel.dart';
import '../l10n/app_strings.dart';
import '../recording/recording_session.dart';
import 'app_model.dart';
import 'format.dart';
import 'stats_panel.dart';

/// The angle equivalent to [course] (mod 360) closest to [reference] —
/// the camera rotation the course is applied against — so a course
/// crossing the 0/360 boundary rotates through the short arc, never the
/// long way around.
double nearestEquivalentRotation(double course, double reference) =>
    course + 360 * ((reference - course) / 360).roundToDouble();

/// The display name of a rotation mode, for the chip button's tooltip and
/// the Settings segments.
String rotationModeName(AppStrings strings, String mode) => switch (mode) {
      'course' => strings.rotationModeCourse,
      'compass' => strings.rotationModeCompass,
      _ => strings.rotationModeNorth,
    };

/// The chip button's icon for a rotation mode.
IconData rotationModeIcon(String mode) => switch (mode) {
      'course' => Icons.trending_flat,
      'compass' => Icons.compass_calibration,
      _ => Icons.north,
    };

/// The recording dashboard: everything a running session shows, and the
/// follow-camera that rides it. Extracted from `map_page.dart`'s state
/// (which keeps the map, the fog overlay, the locate/record buttons and
/// the fits): the HUD chip with
/// its per-fix duration/distance readout and the expandable stats panel —
/// a child of the page's bottom stack (the headline speed rides just under
/// it, see `RecordingSpeedReadout`) — the screen latch, and
/// the follow-camera release-on-gesture semantics. The widget listens to the
/// per-fix channel ([AppModel.recordingLive]) with a [ListenableBuilder],
/// so a 1 Hz fix repaints the dashboard — and only the dashboard; the
/// map's other layers never rebuild for a fix except where they
/// subscribe themselves (the trace and marker layers in `map_page.dart`).
class RecordingDashboard extends StatefulWidget {
  const RecordingDashboard({
    super.key,
    required this.model,
    required this.mapController,
  });

  final AppModel model;
  final MapController mapController;

  @override
  RecordingDashboardState createState() => RecordingDashboardState();
}

class RecordingDashboardState extends State<RecordingDashboard> {
  /// The follow-camera: a new session arms it, a user pan or two-finger
  /// rotation releases it — a fix must never pull the view back against
  /// the user's hand. The locate button's shortcut re-arms it immediately
  /// via [rearmFollow]/[armFollow].
  bool _follow = false;

  /// When the last fix was applied; a longer gap than [gpsLossHold] means
  /// the heading is stale and the rotation is held.
  DateTime? _lastFixAt;

  /// The last [headingSmoothingWindow] headings used for rotation, averaged
  /// circularly into the rotation target (see [_onRecordingFix]).
  final List<double> _recentHeadings = [];

  /// Latest compass heading (rotation-vector fused), used in compass mode —
  /// where the GPS course says where the user *was*.
  double? _compassHeading;

  /// Whether the rotation currently takes its heading from the compass
  /// (below [compassEnterGateMps]) rather than the GPS course; switches only
  /// across the hysteresis band between the two gates.
  bool _compassMode = false;

  /// The compass subscription, alive only while recording with rotation
  /// on (battery hygiene: no continuous sensor stream otherwise).
  StreamSubscription<double?>? _compassSub;

  /// Detects the session boundary (start/stop) to re-arm the follow and
  /// reset the panel.
  bool _wasRecording = false;

  /// Whether the stats panel is expanded; the HUD chip toggles it.
  bool _panelOpen = false;

  /// The recording's screen latch: while a session runs and the
  /// `keepScreenOn` setting is on (the default), the screen stays on so
  /// the dashboard stays readable on a bike or in a pocket-free hand.
  /// The flag itself lives on the Android window (see the host channel's
  /// `keepScreenOn`), so it dies with the window — no stale latch
  /// survives a session's end even on a process kill.
  bool _screenOn = false;

  /// Hysteresis for the course-up camera rotation: only rotate the
  /// camera when the course delta vs its current rotation reaches this
  /// many degrees; below, leave the rotation untouched.
  static const double courseDeltaThreshold = 1.0;

  /// Speed gates for switching the rotation's heading source, with
  /// hysteresis (Coros-style): below [compassEnterGateMps] (~2 km/h) the
  /// GPS course is stale or noise, so the compass drives the rotation;
  /// the course takes over again only above [compassExitGateMps]
  /// (~5 km/h). The two thresholds keep a speed hovering at the boundary
  /// from flapping the source fix-to-fix. A fix with unknown speed keeps
  /// the current mode. In compass mode without a compass reading the
  /// camera holds its last rotation instead of spinning at a standstill.
  static const double compassEnterGateMps = 0.6;
  static const double compassExitGateMps = 1.4;

  /// Exponential smoothing for the course-up rotation: each fix that
  /// clears the hysteresis moves the camera this fraction of the way to
  /// the target instead of snapping, so the rotation eases in over a few
  /// 1 Hz fixes rather than stepping.
  static const double rotationSmoothingFactor = 0.4;

  /// Number of recent usable headings averaged (circular mean) into the
  /// rotation target, so 1 Hz heading noise glides instead of stepping the
  /// camera fix by fix. Five fixes is about five seconds at 1 Hz.
  static const int headingSmoothingWindow = 5;

  /// GPS-loss hold: a fix arriving more than this long after the previous
  /// one is stale — hold the last rotation, never rotate on it.
  static const Duration gpsLossHold = Duration(seconds: 10);

  /// Minimum zoom while the follow-camera rides a session, so the
  /// recording view never gets too zoomed out.
  static const double followZoomFloor = 17.0;

  /// The follow-camera offsets this fraction of the screen height opposite
  /// screen-up from the fix, so the position marker sits horizontally
  /// centered but slightly below the vertical center — more of what is
  /// ahead stays in view.
  static const double followLeadFraction = 0.18;

  /// Compass stream override for tests; production reads
  /// [FlutterCompass.events].
  static Stream<double?> Function() compassEvents =
      () => FlutterCompass.events!.map((e) => e.heading);

  /// Map-event sources that count as the user's hand moving the map: a drag,
  /// a multi-finger gesture, or the fling/double-tap-zoom animations that
  /// continue a gesture after its end. Plain taps and long-presses don't
  /// move the camera, so they must not release the follow — a stray tap in
  /// a mount or pocket would silently disengage the centering mid-ride.
  /// Everything not listed here (programmatic moves, taps, flag changes)
  /// leaves the follow armed.
  static const _moveGestures = <MapEventSource>{
    MapEventSource.dragStart,
    MapEventSource.onDrag,
    MapEventSource.dragEnd,
    MapEventSource.multiFingerGestureStart,
    MapEventSource.onMultiFinger,
    MapEventSource.multiFingerEnd,
    MapEventSource.flingAnimationController,
    MapEventSource.doubleTapZoomAnimationController,
  };

  StreamSubscription<MapEvent>? _mapEvents;

  @override
  void initState() {
    super.initState();
    _wasRecording = widget.model.isRecording;
    _follow = _wasRecording; // A destroyed-and-rebuilt widget re-arms.
    widget.model.addListener(_onModelChanged);
    widget.model.recordingLive.addListener(_onRecordingFix);
    _updateCompassSubscription();
    // The follow-camera releases on a gesture that moves the map — drags,
    // multi-finger gestures, and the fling/double-tap-zoom animations that
    // report through their own sources after the gesture ends. Plain taps
    // don't release it. Only a locate-button tap re-arms it.
    _mapEvents = widget.mapController.mapEventStream.listen((event) {
      if (!_follow || !_moveGestures.contains(event.source)) return;
      _releaseFollow(event.source);
    });
    // The startup salvage notice: a killed session's staged recording was
    // imported during [AppModel.load]; one toast says so. Read once the
    // map mounts — the names are read once and never re-announced.
    _announceSalvagedRecordings();
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    widget.model.recordingLive.removeListener(_onRecordingFix);
    _mapEvents?.cancel();
    _compassSub?.cancel();
    super.dispose();
  }

  /// Releases the follow on a user gesture that moved the map; only a
  /// locate-button tap ([armFollow]/[rearmFollow]) or a new session arms it
  /// again. The releasing event's source goes to the debug log so a later
  /// export shows whether a drag or a stray tap disengaged the follow.
  void _releaseFollow(MapEventSource source) {
    DebugLog.instance.info('follow released by gesture (source=${source.name})');
    setState(() => _follow = false);
  }

  /// Starts the compass stream while recording with rotation on, so a
  /// below-speed-gate fix can still track which way the user faces.
  void _updateCompassSubscription() {
    final want =
        widget.model.isRecording && widget.model.mapRotation != 'north';
    if (want && _compassSub == null) {
      _compassSub = compassEvents().listen((heading) {
        if (!mounted) return;
        _compassHeading = heading;
      });
    } else if (!want && _compassSub != null) {
      _compassSub?.cancel();
      _compassSub = null;
      _compassHeading = null;
    }
  }

  /// The startup salvage toast (see [initState]).
  void _announceSalvagedRecordings() {
    final names = widget.model.salvagedRecordingNames;
    if (names.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final strings = AppStrings.ofContext(context);
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.salvagedRecording(names.join(', ')))),
      );
    });
  }

  /// The session boundary re-arms the follow-camera (the old marker and
  /// any open panel are gone with it). Every model change also re-applies
  /// the screen latch, so the `keepScreenOn` setting takes effect
  /// immediately — even mid-session.
  void _onModelChanged() {
    if (!mounted) return;
    final recording = widget.model.isRecording;
    if (recording != _wasRecording) {
      setState(() {
        _wasRecording = recording;
        _follow = recording;
        _panelOpen = false;
      });
      _lastFixAt = null;
      _recentHeadings.clear();
      _compassMode = false;
    }
    _updateCompassSubscription();
    // Applied best-effort from here: the window flag matters only while
    // the dashboard is in front anyway.
    _applyScreenOn();
  }

  /// The follow-camera rides each accepted fix while it is armed; the
  /// marker, HUD and trace rebuild off the session's own getters. No
  /// setState: fixes arrive at 1 Hz, so the live subtrees rebuild through
  /// the recording-live Listenable and the rest of the map stays still.
  void _onRecordingFix() {
    if (!mounted) return;
    if (!widget.model.isRecording || !_follow) return;
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return;
    // The rotation mode is one of AppModel.rotationModes. 'north': the
    // camera stays north-up while the follow still centers on the fix —
    // the marker keeps pointing along the course on screen. 'course':
    // the rotation is gated on the device's *reported* heading, not the
    // bridged course: a magnetometer-less or bearing-only fix stream
    // keeps the camera north-up, because a bearing between fixes says
    // where the user was, not where they face. 'compass': the rotation
    // follows the compass whenever one is available, regardless of speed.
    // No heading yet — a first fix — leaves the camera rotation alone.
    // In compass-driven rotation without a compass reading the camera
    // holds its last rotation: at a standstill the reported heading is
    // stale, not a direction. A fix arriving more than [gpsLossHold]
    // after the previous one is stale too: hold the rotation on it.
    final now = DateTime.now();
    final stale = _lastFixAt != null && now.difference(_lastFixAt!) > gpsLossHold;
    _lastFixAt = now;
    final heading = session?.currentHeading;
    final speed = session?.currentSpeed;
    // Two-threshold hysteresis: enter compass mode below the enter gate,
    // leave it only above the exit gate, so a speed hovering between the
    // two does not flap the heading source fix-to-fix. A fix with unknown
    // speed keeps the current mode.
    if (speed != null) {
      if (!_compassMode && speed < compassEnterGateMps) {
        _compassMode = true;
        DebugLog.instance.info(
          'compass mode on (speed=${speed.toStringAsFixed(1)})',
        );
      } else if (_compassMode && speed > compassExitGateMps) {
        _compassMode = false;
        DebugLog.instance.info(
          'compass mode off (speed=${speed.toStringAsFixed(1)})',
        );
      }
    }
    final mode = widget.model.mapRotation;
    // 'compass' mode drives the rotation from the compass whenever one is
    // available, regardless of speed; 'course' mode does so only in
    // compass mode (below the hysteresis gate).
    final compassDriven = mode == 'compass' || _compassMode;
    final effectiveHeading =
        (compassDriven && _compassHeading != null) ? _compassHeading : heading;
    if (compassDriven && _compassHeading != null) {
      DebugLog.instance.info(
        'compass override: heading=${_compassHeading!.toStringAsFixed(1)} '
        'gpsHeading=${heading?.toStringAsFixed(1)} speed=${speed?.toStringAsFixed(1)}',
      );
    }
    // Frame the fix slightly below the vertical center in screen space:
    // shift the camera center opposite screen-up (geographic bearing
    // 360 - rotation) by a fraction of the screen height, so the position
    // sits bottom-center in both north-up and course-up modes.
    final zoom = math.max(
      widget.mapController.camera.zoom,
      followZoomFloor,
    );
    var center = LatLng(lat, lon);
    final view = View.of(context);
    final height = view.physicalSize.height / view.devicePixelRatio;
    if (height > 0) {
      final metersPerPixel =
          156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
      final offsetMeters = metersPerPixel * height * followLeadFraction;
      final upRad = (360 - widget.mapController.camera.rotation) * math.pi / 180;
      center = LatLng(
        lat + offsetMeters * math.cos(upRad) / 111320,
        lon +
            offsetMeters *
                math.sin(upRad) /
                (111320 * math.cos(lat * math.pi / 180)),
      );
    }
    if (effectiveHeading == null ||
        stale ||
        mode == 'north' ||
        (compassDriven && _compassHeading == null)) {
      widget.mapController.move(center, zoom);
    } else {
      // With a reported heading, currentCourse is that same heading. The
      // rotation target is the circular mean of the last few usable
      // headings (atan2 of summed sin/cos — wrap-safe across 0/360), so
      // heading noise averages out instead of stepping the camera.
      _recentHeadings.add(effectiveHeading);
      if (_recentHeadings.length > headingSmoothingWindow) {
        _recentHeadings.removeAt(0);
      }
      var sinSum = 0.0;
      var cosSum = 0.0;
      for (final h in _recentHeadings) {
        final rad = h * math.pi / 180;
        sinSum += math.sin(rad);
        cosSum += math.cos(rad);
      }
      final meanHeading = math.atan2(sinSum, cosSum) * 180 / math.pi;
      // flutter_map applies a positive camera rotation clockwise on screen
      // (the map content is wrapped in Transform.rotate(rotationRad)), so a
      // geographic bearing shows up at screen bearing bearing + rotation.
      // Course-up therefore needs rotation = -heading, not +heading.
      final target = -meanHeading;
      final rotation = widget.mapController.camera.rotation;
      final courseDelta =
          nearestEquivalentRotation(target, rotation) - rotation;
      if (courseDelta.abs() >= courseDeltaThreshold) {
        final applied = rotation + courseDelta * rotationSmoothingFactor;
        DebugLog.instance.info(
          'rotate: mean=${meanHeading.toStringAsFixed(1)} '
          'target=${target.toStringAsFixed(1)} '
          'from=${rotation.toStringAsFixed(1)} to=${applied.toStringAsFixed(1)}',
        );
        widget.mapController.moveAndRotate(
          center,
          zoom,
          applied,
        );
      } else {
        widget.mapController.move(center, zoom);
      }
    }
  }

  /// Applies the latch if it changed: on while a session runs and the
  /// `keepScreenOn` setting is on. Best effort: a platform without the
  /// host channel (desktop, tests) has no window to latch; its OS timeout
  /// applies.
  Future<void> _applyScreenOn() async {
    final on = widget.model.isRecording && widget.model.keepScreenOn;
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

  /// Arms the follow without moving the camera: used by the locate
  /// attempt's success while a session runs — the attempt fix is at the
  /// map's center already, and the next session fix takes over.
  void armFollow() {
    if (!_follow) {
      DebugLog.instance.info('follow armed (locate)');
      setState(() => _follow = true);
    }
  }

  /// The locate shortcut's way back to the follow after a pan away:
  /// arms the follow and re-centers on the session's fix at the user's
  /// zoom, so the camera and the course-up rotation come back with the
  /// next fix — no second GPS request and no spinner.
  void rearmFollow() {
    armFollow();
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return;
    widget.mapController.move(
      LatLng(lat, lon),
      widget.mapController.camera.zoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.model.recording;
    if (session == null) return const SizedBox.shrink();
    // Per-fix only: a 1 Hz fix repaints the session-driven readouts and
    // nothing else. Boundary and latch changes rebuild through
    // _onModelChanged's setState; the toggles through their own.
    return ListenableBuilder(
      listenable: widget.model.recordingLive,
      builder: (context, _) {
        final live = widget.model.recording;
        if (live == null) return const SizedBox.shrink();
        final strings = AppStrings.ofContext(context);
        return _dashboard(live, strings);
      },
    );
  }

  /// The dashboard's part: the HUD chip and the expandable stats panel,
  /// as one child of the page's bottom column (under the selection bar,
  /// above the speed readout and the action stack — see `MapPage`). The
  /// headline speed rides just under it (`RecordingSpeedReadout`).
  Widget _dashboard(RecordingSession session, AppStrings strings) {
    final meters = session.distanceMeters;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            child: InkWell(
              key: const ValueKey('recording-chip'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _panelOpen = !_panelOpen),
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
                    IconButton(
                      key: const ValueKey('rotation-mode-button'),
                      tooltip: rotationModeName(
                        strings,
                        widget.model.mapRotation,
                      ),
                      icon: Icon(rotationModeIcon(widget.model.mapRotation)),
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        final modes = AppModel.rotationModes;
                        final next =
                            modes[(modes.indexOf(widget.model.mapRotation) +
                                    1) %
                                modes.length];
                        widget.model.setMapRotation(next);
                      },
                    ),
                    Icon(
                      _panelOpen ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: Theme.of(context).hintColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_panelOpen) StatsPanel(session: session, strings: strings),
        ],
      ),
    );
  }
}

/// The dashboard's primary readout: the live speed, big — the stem display
/// a bike computer shows the rider. It is a child of the page's bottom
/// column, directly under the recording chip. Before the first fix and
/// while paused (paused sessions are silent) it shows a dash, like the
/// stats panel's not-yet-measured values. The per-fix channel rebuilds
/// only this card.
class RecordingSpeedReadout extends StatelessWidget {
  const RecordingSpeedReadout({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model.recordingLive,
      builder: (context, _) {
        final session = model.recording;
        if (session == null) return const SizedBox.shrink();
        final currentSpeed = session.currentSpeed;
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Card(
            key: const ValueKey('recording-speed'),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 10,
              ),
              child: Text(
                currentSpeed == null
                    ? '—'
                    : '${(currentSpeed * 3.6).toStringAsFixed(1)} km/h',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
          ),
        );
      },
    );
  }
}
