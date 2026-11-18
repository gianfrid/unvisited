import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
      _ => strings.rotationModeNorth,
    };

/// The chip button's icon for a rotation mode: a compass rose while the
/// map is locked north-up, the travel arrow (the position marker's glyph)
/// while the camera rides the course.
IconData rotationModeIcon(String mode) => switch (mode) {
      'course' => Icons.navigation,
      _ => Icons.explore,
    };

/// The recording dashboard: everything a running session shows, and the
/// follow-camera that rides it. Extracted from `map_page.dart`'s state
/// (which keeps the map, the fog overlay, the locate/record buttons and
/// the fits): the HUD chip with its per-fix duration, distance and
/// headline speed in one row, and the expandable stats panel — a child of
/// the page's bottom stack — the screen latch, and the follow-camera
/// release-on-gesture semantics. The widget listens to the
/// per-fix channel ([AppModel.recordingLive]) with a [ListenableBuilder],
/// so a 1 Hz fix repaints the dashboard — and only the dashboard; the
/// map's other layers never rebuild for a fix except where they
/// subscribe themselves (the trace and marker layers in `map_page.dart`).
class RecordingDashboard extends StatefulWidget {
  const RecordingDashboard({
    super.key,
    required this.model,
    required this.mapController,
    required this.markerRotation,
    required this.bottomOverlap,
  });

  final AppModel model;
  final MapController mapController;

  /// The camera rotation the map page's recording marker draws against;
  /// published here after every rotation this dashboard applies (and after
  /// a gesture rotation), so the marker reads the post-move value in the
  /// same frame instead of lagging a fix behind (see `MapPage`).
  final ValueNotifier<double> markerRotation;

  /// Pixels the page's bottom overlay column occupies from the screen
  /// bottom right now (see `MapPage.bottomOverlap`): the follow-camera
  /// keeps the fix above it, so the marker never hides under the HUD.
  final double Function() bottomOverlap;

  @override
  RecordingDashboardState createState() => RecordingDashboardState();
}

class RecordingDashboardState extends State<RecordingDashboard>
    with TickerProviderStateMixin {
  /// The follow-camera: a new session arms it, a user pan or two-finger
  /// rotation releases it — a fix must never pull the view back against
  /// the user's hand. The locate button's shortcut re-arms it immediately
  /// via [rearmFollow]/[armFollow].
  bool _follow = false;

  /// The follow-camera glide: each fix stores its target here and the
  /// ticker below eases the camera toward it frame by frame (flutter_map's
  /// move is instant, so the 1 Hz fixes would otherwise stutter the view).
  /// Null when nothing is gliding.
  ({LatLng center, double zoom, double rotation})? _glideTarget;

  /// The glide ticker, alive only while a target is pending or in flight.
  Ticker? _glideTicker;

  /// Elapsed time at the previous glide frame, for the per-frame delta.
  Duration _prevGlideElapsed = Duration.zero;

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

  /// Hysteresis for the course-up camera rotation: a fix only sets a new
  /// rotation target when the course delta vs the current rotation reaches
  /// this many degrees; below, the target keeps the current rotation.
  static const double courseDeltaThreshold = 1.0;

  /// Time constant of the follow-camera glide (exponential approach,
  /// critical-damped per frame): τ ≈ 350 ms, so the camera converges over
  /// roughly a second after each fix instead of snapping at 1 Hz.
  static const Duration followGlideTau = Duration(milliseconds: 350);

  /// Settle epsilons below which the glide stops and the ticker idles:
  /// the camera must not repaint at a standstill.
  static const double _glideZoomEpsilon = 0.001;
  static const double _glideLatEpsilon = 1e-7;
  static const double _glideLonEpsilon = 1e-7;
  static const double _glideRotationEpsilon = 0.05;

  /// Speed gates for switching the rotation's heading source, with
  /// hysteresis (Coros-style): below [compassEnterGateMps] (~2 km/h) the
  /// GPS course is stale or noise, so the compass drives the rotation;
  /// the course takes over again only above [compassExitGateMps]
  /// (~5 km/h). The two thresholds keep a speed hovering at the boundary
  /// from flapping the source fix-to-fix. A fix with unknown speed keeps
  /// the current mode. While the compass drives the rotation without a
  /// compass reading the camera holds its last rotation instead of
  /// spinning at a standstill.
  static const double compassEnterGateMps = 0.6;
  static const double compassExitGateMps = 1.4;

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

  /// The follow-camera offsets at most this fraction of the screen height
  /// opposite screen-up from the fix, so the position marker sits
  /// horizontally centered but slightly below the vertical center — more
  /// of what is ahead stays in view. The lead shrinks when the bottom
  /// overlay column needs the room (see [followLeadMargin] and
  /// [RecordingDashboard.bottomOverlap]) so the marker never hides under
  /// the HUD; on a short screen with the panel open it reaches zero and
  /// the fix sits at the center.
  static const double followLeadFraction = 0.18;

  /// Breathing room between the marker and the top of the bottom overlay
  /// column.
  static const double followLeadMargin = 16;

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
      // A gesture rotation (armed or after a release) moves the camera
      // under the marker: republish so the nose keeps tracking the course
      // on screen.
      _publishRotation();
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
    _stopGlide();
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
    // The pan owns the camera now: stop any in-flight glide, or the next
    // frame would pull the view back against the user's hand.
    _stopGlide();
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
      _stopGlide();
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
    // where the user was, not where they face. No heading yet — a first
    // fix — leaves the camera rotation alone. In compass-driven rotation
    // (below the speed gate) without a compass reading the camera holds
    // its last rotation: at a standstill the reported heading is stale,
    // not a direction. A fix arriving more than [gpsLossHold] after the
    // previous one is stale too: hold the rotation on it.
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
    // Below the hysteresis gate the compass drives the rotation instead
    // of the (stale or noisy) GPS course.
    final compassDriven = _compassMode;
    final effectiveHeading =
        (compassDriven && _compassHeading != null) ? _compassHeading : heading;
    if (compassDriven && _compassHeading != null) {
      DebugLog.instance.info(
        'compass override: heading=${_compassHeading!.toStringAsFixed(1)} '
        'gpsHeading=${heading?.toStringAsFixed(1)} speed=${speed?.toStringAsFixed(1)}',
      );
    }
    final zoom = math.max(
      widget.mapController.camera.zoom,
      followZoomFloor,
    );
    final center = _framedCenter(lat, lon, zoom);
    double targetRotation;
    if (effectiveHeading == null ||
        stale ||
        mode == 'north' ||
        (compassDriven && _compassHeading == null)) {
      // No usable heading this fix: glide to the new center/zoom but keep
      // the current rotation.
      targetRotation = widget.mapController.camera.rotation;
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
      targetRotation =
          courseDelta.abs() >= courseDeltaThreshold ? target : rotation;
      DebugLog.instance.info(
        'glide target: mean=${meanHeading.toStringAsFixed(1)} '
        'rotation=${targetRotation.toStringAsFixed(1)}',
      );
    }
    _setGlideTarget(center, zoom, targetRotation);
  }

  /// Stores the camera target for the next fix (or re-frame) and starts the
  /// glide ticker if it is not running. The ticker eases the camera toward
  /// it frame by frame; flutter_map's move is instant, so without it the
  /// 1 Hz fixes would stutter the view.
  void _setGlideTarget(LatLng center, double zoom, double rotation) {
    _glideTarget = (center: center, zoom: zoom, rotation: rotation);
    _prevGlideElapsed = Duration.zero;
    _glideTicker ??= createTicker(_glideTick)..start();
  }

  /// One glide frame: exponential approach (critical damped, τ =
  /// [followGlideTau]) of center, zoom and rotation toward the target,
  /// rotation through the short arc. One `moveAndRotate` per frame, and the
  /// marker rotation is published so the marker layer tracks the same
  /// frame. Stops the ticker once settled — no repaint at a standstill.
  void _glideTick(Duration elapsed) {
    final target = _glideTarget;
    if (!mounted || target == null) {
      _stopGlide();
      return;
    }
    final dtMs = (elapsed - _prevGlideElapsed).inMilliseconds;
    _prevGlideElapsed = elapsed;
    final k =
        dtMs <= 0
            ? 0.0
            : 1 - math.exp(-dtMs / followGlideTau.inMilliseconds.toDouble());
    final camera = widget.mapController.camera;
    final newLat =
        camera.center.latitude + (target.center.latitude - camera.center.latitude) * k;
    final newLon =
        camera.center.longitude +
        (target.center.longitude - camera.center.longitude) * k;
    final newZoom = camera.zoom + (target.zoom - camera.zoom) * k;
    final rotDelta =
        nearestEquivalentRotation(target.rotation, camera.rotation) -
        camera.rotation;
    final newRotation = camera.rotation + rotDelta * k;
    widget.mapController.moveAndRotate(
      LatLng(newLat, newLon),
      newZoom,
      newRotation,
    );
    _publishRotation();
    // Settle on the *remaining* distance, not the frame's step: stopping on
    // a small step would leave up to step/(1-k) of residual behind.
    final remainingRot =
        (nearestEquivalentRotation(target.rotation, newRotation) - newRotation)
            .abs();
    if (k > 0 &&
        (target.zoom - newZoom).abs() < _glideZoomEpsilon &&
        (target.center.latitude - newLat).abs() < _glideLatEpsilon &&
        (target.center.longitude - newLon).abs() < _glideLonEpsilon &&
        remainingRot < _glideRotationEpsilon) {
      // Settled: snap to the exact target so no epsilon-sized residual
      // (e.g. the zoom floor) is left behind, then idle.
      widget.mapController.moveAndRotate(
        target.center,
        target.zoom,
        target.rotation,
      );
      _publishRotation();
      _stopGlide();
    }
  }

  /// Stops the glide and forgets the target: the user's hand owns the
  /// camera after a pan, the session owns it after it ends.
  void _stopGlide() {
    _glideTicker?.stop();
    _glideTicker?.dispose();
    _glideTicker = null;
    _glideTarget = null;
    _prevGlideElapsed = Duration.zero;
  }

  /// The camera center for a fix: shifted opposite screen-up (geographic
  /// bearing 360 - rotation) so the position sits below the vertical
  /// center — bottom-center in both north-up and course-up modes, with
  /// more of what is ahead in view. The lead is capped by the room the
  /// bottom overlay column leaves, so the marker never hides under the
  /// HUD; a short screen with the panel open puts the fix at the center.
  LatLng _framedCenter(double lat, double lon, double zoom) {
    final view = View.of(context);
    final height = view.physicalSize.height / view.devicePixelRatio;
    if (height <= 0) return LatLng(lat, lon);
    final lead = math.min(
      height * followLeadFraction,
      math.max(height / 2 - widget.bottomOverlap() - followLeadMargin, 0),
    );
    if (lead <= 0) return LatLng(lat, lon);
    final metersPerPixel =
        156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
    final offsetMeters = metersPerPixel * lead;
    final upRad = (360 - widget.mapController.camera.rotation) * math.pi / 180;
    return LatLng(
      lat + offsetMeters * math.cos(upRad) / 111320,
      lon +
          offsetMeters *
              math.sin(upRad) /
              (111320 * math.cos(lat * math.pi / 180)),
    );
  }

  /// Re-applies the follow framing to the session's last fix without
  /// touching the rotation — used when the bottom column's height changes
  /// (the stats panel opens or closes) while the follow is armed.
  void _recenterOnFix() {
    if (!mounted || !widget.model.isRecording || !_follow) return;
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return;
    final zoom = math.max(widget.mapController.camera.zoom, followZoomFloor);
    // The panel's new size is laid out by the frame this setState
    // schedules; measure and move once it has.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Glide to the re-framed position (panel toggle), keeping the
      // current rotation.
      _setGlideTarget(
        _framedCenter(lat, lon, zoom),
        zoom,
        widget.mapController.camera.rotation,
      );
    });
  }

  /// Publishes the camera rotation the recording marker draws against.
  /// Called after every move this dashboard applies, so the marker reads
  /// the post-move value in the same frame (see `MapPage._markerRotation`).
  void _publishRotation() {
    final rotation = widget.mapController.camera.rotation;
    if (widget.markerRotation.value != rotation) {
      widget.markerRotation.value = rotation;
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
  /// as one child of the page's bottom column (under the selection bar and
  /// the action stack — see `MapPage`). The chip carries the headline
  /// speed alongside the duration and distance: one row, so the column
  /// stays short enough for the follow-camera to keep the marker above it.
  Widget _dashboard(RecordingSession session, AppStrings strings) {
    final meters = session.distanceMeters;
    final speed = session.currentSpeed;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            child: InkWell(
              key: const ValueKey('recording-chip'),
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                setState(() => _panelOpen = !_panelOpen);
                // The column just grew or shrank: re-frame now instead of
                // on the next fix, so the marker never sits under the
                // panel for up to a second.
                _recenterOnFix();
              },
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
                    const SizedBox(width: 10),
                    // The headline speed — the stem display a bike computer
                    // shows the rider. A dash before the first fix and
                    // while paused (paused sessions are silent). Bounded so
                    // a large text scale ellipsizes instead of overflowing
                    // the row, while the chip keeps its compact width.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 84),
                      child: Text(
                        speed == null
                            ? '—'
                            : '${(speed * 3.6).toStringAsFixed(1)} km/h',
                        key: const ValueKey('recording-speed'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 4),
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
