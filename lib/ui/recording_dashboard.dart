import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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

/// The recording dashboard: everything a running session shows, and the
/// follow-camera that rides it. Extracted from `map_page.dart`'s state
/// (which keeps the map, the fog overlay, the locate/record buttons and
/// the fits): the HUD chip with
/// its per-fix duration/distance readout and the screen-latch toggle, the
/// expandable stats panel, the bottom-center headline speed, and the
/// follow-camera release-on-gesture semantics. The widget listens to the
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
  /// The follow-camera: a new session arms it, a user pan releases it —
  /// a fix must never pull the view back against the user's hand. The
  /// locate button's shortcut re-arms it via [rearmFollow]/[armFollow].
  bool _follow = false;

  /// Detects the session boundary (start/stop) to re-arm the follow and
  /// reset the panel and the screen-latch opt-out (a new session keeps
  /// the screen on again).
  bool _wasRecording = false;

  /// Whether the stats panel is expanded; the HUD chip toggles it.
  bool _panelOpen = false;

  /// The recording's screen latch: the session keeps the screen on so the
  /// dashboard stays readable on a bike or in a pocket-free hand. The
  /// latch is a per-session default-on that the chip's screen-lock icon
  /// toggles; the flag itself lives on the Android window (see the host
  /// channel's `keepScreenOn`), so it dies with the window — no stale
  /// latch survives a session's end even on a process kill.
  bool _screenLockOff = false;
  bool _screenOn = false;

  /// Hysteresis for the course-up camera rotation: only rotate the
  /// camera when the course delta vs its current rotation reaches this
  /// many degrees; below, leave the rotation untouched.
  static const double courseDeltaThreshold = 1.0;

  /// Map-event sources that are not the user's hand: programmatic moves
  /// (the follow-camera itself, the zoom slider), camera fits, customs.
  /// Everything else releases the follow.
  static const _programmaticEvents = <MapEventSource>{
    MapEventSource.mapController,
    MapEventSource.fitCamera,
    MapEventSource.custom,
  };

  StreamSubscription<MapEvent>? _mapEvents;

  @override
  void initState() {
    super.initState();
    _wasRecording = widget.model.isRecording;
    _follow = _wasRecording; // A destroyed-and-rebuilt widget re-arms.
    widget.model.addListener(_onModelChanged);
    widget.model.recordingLive.addListener(_onRecordingFix);
    // The follow-camera releases on any gesture move — including the
    // fling/double-tap-zoom animations that report through their own
    // sources after the gesture ends.
    _mapEvents = widget.mapController.mapEventStream.listen((event) {
      if (!_follow || _programmaticEvents.contains(event.source)) return;
      setState(() => _follow = false);
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
    super.dispose();
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
  /// any open panel are gone with it) and resets the screen latch's
  /// opt-out: a new session keeps the screen on again.
  void _onModelChanged() {
    if (!mounted) return;
    final recording = widget.model.isRecording;
    if (recording != _wasRecording) {
      setState(() {
        _wasRecording = recording;
        _follow = recording;
        _panelOpen = false;
        _screenLockOff = false;
      });
    }
    // Applied best-effort from here and from the chip's toggle: the
    // window flag matters only while the dashboard is in front anyway.
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
    // Course-up: while the follow holds, the camera rotates to the
    // current course so where the user is going stays ahead of them —
    // course-up makes the motion read upward on screen. The rotation
    // emits controller events (programmatic sources), so this never
    // releases the follow; any hand gesture still does, and with it the
    // rotation. nearestEquivalentRotation keeps the short arc where the
    // course crosses 0/360. The rotation is gated on the device's
    // *reported* heading, not the bridged course: a magnetometer-less or
    // bearing-only fix stream keeps the camera north-up (the marker
    // still rotates with the course), because a bearing between fixes
    // says where the user was, not where they face. No heading yet — a
    // first fix — leaves the camera rotation alone.
    final heading = session?.currentHeading;
    if (heading == null) {
      widget.mapController.move(
        LatLng(lat, lon),
        widget.mapController.camera.zoom,
      );
    } else {
      // With a reported heading, currentCourse is that same heading.
      final rotation = widget.mapController.camera.rotation;
      final courseDelta =
          nearestEquivalentRotation(heading, rotation) - rotation;
      if (courseDelta.abs() >= courseDeltaThreshold) {
        widget.mapController.moveAndRotate(
          LatLng(lat, lon),
          widget.mapController.camera.zoom,
          nearestEquivalentRotation(heading, rotation),
        );
      } else {
        widget.mapController.move(
          LatLng(lat, lon),
          widget.mapController.camera.zoom,
        );
      }
    }
  }

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

  /// Arms the follow without moving the camera: used by the locate
  /// attempt's success while a session runs — the attempt fix is at the
  /// map's center already, and the next session fix takes over.
  void armFollow() {
    if (!_follow) setState(() => _follow = true);
  }

  /// The locate shortcut's way back to the follow after a pan away:
  /// arms the follow and re-centers on the session's fix at the user's
  /// zoom, so the camera and the course-up rotation come back with the
  /// next fix — no second GPS request and no spinner.
  void rearmFollow() {
    setState(() => _follow = true);
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
    return ListenableBuilder(
      listenable: Listenable.merge([widget.model, widget.model.recordingLive]),
      builder: (context, _) {
        final live = widget.model.recording;
        if (live == null) return const SizedBox.shrink();
        final sessionStrings = AppStrings.ofContext(context);
        return _dashboard(live, sessionStrings);
      },
    );
  }

  Widget _dashboard(RecordingSession session, AppStrings strings) {
    final meters = session.distanceMeters;
    final currentSpeed = session.currentSpeed;
    return Stack(
      children: [
        Positioned(
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
                            _panelOpen ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                            color: Theme.of(context).hintColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_panelOpen) StatsPanel(session: session, strings: strings),
            ],
          ),
        ),
        // The dashboard's primary readout: the live speed, big and
        // bottom-center — the stem display a bike computer shows the
        // rider. Before the first fix and while paused (paused sessions
        // are silent) it shows a dash, like the stats panel's
        // not-yet-measured values.
        Positioned(
          bottom: 24,
          left: 0,
          right: 0,
          child: Center(
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
          ),
        ),
      ],
    );
  }
}
