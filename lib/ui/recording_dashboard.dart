import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../debug_log.dart';
import '../host_channel.dart';
import '../l10n/app_strings.dart';
import '../recording/recording_session.dart';
import 'app_model.dart';
import 'follow_camera.dart';
import 'format.dart';
import 'stats_panel.dart';

// The follow-camera lives in `follow_camera.dart` now; the top-level
// rotation helper is re-exported so existing importers of this library
// (including the tests) keep resolving it unchanged.
export 'follow_camera.dart' show nearestEquivalentRotation;

// The rotation-mode display helpers (rotationModeName/rotationModeIcon)
// live in `map_controls.dart` now: the toggle is the map pill's button,
// not a chip button.

/// The recording dashboard: everything a running session shows. Extracted
/// from `map_page.dart`'s state (which keeps the map, the fog overlay, the
/// locate/record buttons and the fits): the HUD chip with its per-fix
/// duration and distance in one row, and the expandable stats panel — a
/// child of the page's bottom stack — the screen latch, and the
/// follow-camera wiring that rides the session's fixes
/// (the [FollowCamera] module itself is shared with track playback; see
/// there). The headline speed is not here: it lives in the top bar's
/// center (see `RecordingSpeedSegment` in `map_actions.dart`). The widget
/// listens to the per-fix channel ([AppModel.recordingLive]) with a
/// [ListenableBuilder], so a 1 Hz fix repaints the dashboard — and only
/// the dashboard; the map's other layers never rebuild for a fix except
/// where they subscribe themselves (the trace and marker layers in
/// `map_page.dart`).
class RecordingDashboard extends StatefulWidget {
  const RecordingDashboard({
    super.key,
    required this.model,
    required this.mapController,
    required this.bottomOverlap,
    this.onFollowChanged,
  });

  final AppModel model;
  final MapController mapController;

  /// Pixels the page's bottom overlay column occupies from the screen
  /// bottom right now (see `MapPage.bottomOverlap`): the follow-camera
  /// keeps the fix above it, so the marker never hides under the HUD.
  final double Function() bottomOverlap;

  /// Fired whenever the follow-camera flips (armed or released) — the
  /// page's way to rebuild controls that depend on the armed state.
  final void Function()? onFollowChanged;

  @override
  RecordingDashboardState createState() => RecordingDashboardState();
}

class RecordingDashboardState extends State<RecordingDashboard>
    with TickerProviderStateMixin {
  /// The follow-camera, shared with track playback (see
  /// `follow_camera.dart`): this dashboard feeds it the session's fixes
  /// — computing the rotation's heading policy (compass fallback, stale
  /// hold, speed gates) — while the glide, the framing, the
  /// release-on-gesture and the rotation math are the module's.
  late final FollowCamera follow;

  /// True while this dashboard's follow-camera is armed — the map page
  /// reads it to retire the pill's locate slot while the camera is
  /// already locked on the followed point.
  bool get followArmed => follow.follow;

  /// When the last fix was applied; a longer gap than [gpsLossHold] means
  /// the heading is stale and the rotation is held.
  DateTime? _lastFixAt;

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

  /// GPS-loss hold: a fix arriving more than this long after the previous
  /// one is stale — hold the last rotation, never rotate on it.
  static const Duration gpsLossHold = Duration(seconds: 10);

  /// Compass stream override for tests; production reads
  /// [FlutterCompass.events].
  static Stream<double?> Function() compassEvents =
      () => FlutterCompass.events!.map((e) => e.heading);

  @override
  void initState() {
    super.initState();
    follow = FollowCamera(
      mapController: widget.mapController,
      bottomOverlap: widget.bottomOverlap,
      screenHeight: () {
        final view = View.of(context);
        return view.physicalSize.height / view.devicePixelRatio;
      },
      tickerFactory: createTicker,
      onFollowChanged: () {
        if (mounted) setState(() {});
        widget.onFollowChanged?.call();
      },
    );
    _wasRecording = widget.model.isRecording;
    // The session's camera policy: one-finger drags peek (pan live,
    // glide back on lift) rather than release the follow.
    follow.dragPeeks = _wasRecording;
    follow.reset(armed: _wasRecording); // A destroyed-and-rebuilt widget re-arms.
    widget.model.addListener(_onModelChanged);
    widget.model.recordingLive.addListener(_onRecordingFix);
    _updateCompassSubscription();
    // The startup salvage notice: a killed session's staged recording was
    // imported during [AppModel.load]; one toast says so. Read once the
    // map mounts — the names are read once and never re-announced.
    _announceSalvagedRecordings();
  }

  @override
  void dispose() {
    follow.dispose();
    widget.model.removeListener(_onModelChanged);
    widget.model.recordingLive.removeListener(_onRecordingFix);
    _compassSub?.cancel();
    super.dispose();
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

  /// The session boundary resets the shared follow-camera (the old marker
  /// and any open panel are gone with it). Every model change also
  /// re-applies the screen latch, so the `keepScreenOn` setting takes
  /// effect immediately — even mid-session.
  /// The rotation mode last seen, so a mode change clears the follow's
  /// smoothed-heading window (a north-bound 0.0 must not blend with the
  /// previous course's headings, nor vice versa).
  String? _lastRotationMode;

  void _onModelChanged() {
    if (!mounted) return;
    final mode = widget.model.mapRotation;
    if (_lastRotationMode != null && _lastRotationMode != mode) {
      follow.clearHeadingWindow();
    }
    _lastRotationMode = mode;
    final recording = widget.model.isRecording;
    if (recording != _wasRecording) {
      setState(() {
        _wasRecording = recording;
        _panelOpen = false;
      });
      // The session's camera policy rides the boundary with the arm: a
      // running session's one-finger drags peek (pan live, glide back
      // on lift), an ended one's release as always.
      follow.dragPeeks = recording;
      follow.reset(armed: recording);
      _lastFixAt = null;
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
  ///
  /// The rotation mode is one of AppModel.rotationModes. 'north': the
  /// camera stays north-up while the follow still centers on the fix —
  /// the marker keeps pointing along the course on screen. 'course': the
  /// rotation is gated on the device's *reported* heading, not the
  /// bridged course: a magnetometer-less or bearing-only fix stream keeps
  /// the camera north-up, because a bearing between fixes says where the
  /// user was, not where they face. No heading yet — a first fix — leaves
  /// the camera rotation alone. In compass-driven rotation (below the
  /// speed gate) without a compass reading the camera holds its last
  /// rotation: at a standstill the reported heading is stale, not a
  /// direction. A fix arriving more than [gpsLossHold] after the
  /// previous one is stale too: hold the rotation on it. Each of those
  /// conditions feeds the follow-camera a null heading — glide the
  /// position, keep the rotation.
  void _onRecordingFix() {
    if (!mounted) return;
    if (!widget.model.isRecording || !follow.follow) return;
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return;
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
    // North mode feeds 0.0, not null: null means "hold the current
    // rotation" (a stale or compass-less course), while north-up must
    // actively glide the rotation back to 0.
    follow.update(
      LatLng(lat, lon),
      mode == 'north'
          ? 0.0
          : (effectiveHeading == null ||
                  stale ||
                  (compassDriven && _compassHeading == null))
              ? null
              : effectiveHeading,
    );
  }

  /// Re-applies the follow framing to the session's last fix without
  /// touching the rotation — used when the bottom column's height changes
  /// (the stats panel opens or closes) while the follow is armed.
  void _recenterOnFix() {
    if (!mounted || !widget.model.isRecording || !follow.follow) return;
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return;
    // The panel's new size is laid out by the frame this setState
    // schedules; measure and re-frame once it has.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Glide to the re-framed position (panel toggle), keeping the
      // current rotation.
      follow.update(LatLng(lat, lon), null);
    });
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
  void armFollow() => follow.arm();

  /// The locate shortcut's way back to the follow after a pan away:
  /// arms the follow and re-centers on the session's fix at the user's
  /// zoom, so the camera and the course-up rotation come back with the
  /// next fix — no second GPS request and no spinner.
  void rearmFollow() {
    final session = widget.model.recording;
    final lat = session?.currentLat;
    final lon = session?.currentLon;
    if (lat == null || lon == null) return;
    follow.rearm(LatLng(lat, lon));
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
  /// the action stack — see `MapPage`). One row without the headline
  /// speed (it lives in the top bar), so the column stays short enough
  /// for the follow-camera to keep the marker above it.
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
