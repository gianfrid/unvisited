import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../aggregate/member_colors.dart' show MemberColorAssignment;
import '../l10n/app_strings.dart';
import '../playback/track_playback.dart';
import '../recording/recording_session.dart';
import '../tile_source.dart';
import 'app_model.dart';
import 'fog_of_war.dart';
import 'ink_stroke.dart';
import 'lane_offset.dart';
import 'map_actions.dart';
import 'map_controls.dart';
import 'playback_dashboard.dart';
import 'recording_dashboard.dart';
import 'road_coverage_chip.dart';
import 'settings_sheet.dart';
import 'track_colors.dart';
import 'track_list.dart';

/// The little triangle connecting the member bubble to the tapped point.
class _LeaderTipPainter extends CustomPainter {
  _LeaderTipPainter(this.color, {required this.down});

  final Color color;
  final bool down;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = ui.Path();
    if (down) {
      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width / 2, size.height);
    } else {
      path.moveTo(size.width / 2, 0);
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _LeaderTipPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.down != down;
}

/// One member lane in member-picking mode: as drawn and hit-tested —
/// decimated, segment-split, and offset sideways by its lane index.
class _MemberLane {
  _MemberLane(this.id, this.assignment, this.visible, this.segments);

  final String id;
  final MemberColorAssignment assignment;
  final bool visible;
  final List<List<LatLng>> segments;
}

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
    widget.model.player.playbackLive.addListener(_onPlaybackLive);
    // Cross a zoom level: the fog coarseness is keyed to the zoom, so the
    // overlay must be rebuilt when the view moves between zoom levels
    // (the cell grid doubles per band — see fogCellSizeFor).
    _mapEvents = _mapController.mapEventStream.listen((event) {
      final cell = fogCellSizeFor(
        zoom: event.camera.zoom,
        latitude: event.camera.center.latitude,
      );
      var dirty = cell != _fogCellSize;
      final zoomStep = (event.camera.zoom * 2).roundToDouble() / 2;
      _cameraZoom = event.camera.zoom;
      if (!dirty && zoomStep != _fogZoomStep) {
        // Ink strokes and the picking-mode lanes both convert ground
        // meters to pixels per zoom half-step.
        dirty =
            widget.model.fogStyle == 'ink' || widget.model.memberPicking;
      }
      _fogZoomStep = zoomStep;
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
      // Every camera change — gesture or programmatic — is an input to
      // the unvisited-roads chip (flutter_map also emits the controller's
      // own moves here). The debounce restarts, so a burst of camera
      // movement pays one coverage pass once it settles.
      _scheduleCoverageUpdate();
    });
    // Start silently with the last saved position (never prompting) and
    // let a live fix override it once it arrives. With no location
    // permission granted yet this is a no-op — only the locate button
    // asks.
    _silentPositionUpdate();
    _startFixRetryTimer();
    // The startup camera is static: no map event ever announces it, so
    // the unvisited-roads chip gets its first answer here (even a null
    // one — the map starts below the zoom floor with no region).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleCoverageUpdate();
    });
  }

  /// The debounce of the unvisited-roads chip: one coverage pass per
  /// 300 ms of camera stillness. Page-owned on purpose — the model
  /// outlives pages and must never hold a timer no page listens to;
  /// especially when a test swaps the model under a reused element.
  Timer? _coverageDebounce;

  void _scheduleCoverageUpdate() {
    _coverageDebounce?.cancel();
    _coverageDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final visible = _mapController.camera.visibleBounds;
      widget.model.viewportSettled(visible.southWest, visible.northEast);
    });
  }

  late final bool _cacheUsable;

  /// Current fog-cell edge for the explored overlay; updated from map
  /// events in initState and read when the circles are built.
  double _fogCellSize = baseCellSizeMeters;

  /// The camera zoom quantized to half-steps, for the meter-sized ink
  /// style: its stroke widths convert from ground meters to pixels with
  /// the current zoom, so the width refreshes twice per zoom level
  /// without redrawing the (cached) stroke geometry per frame.
  double _fogZoomStep = 0.0;

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

  /// The playback dashboard's state, reached the same way: on platforms
  /// without a location plugin the pill's follow button re-arms the
  /// replay's follow-camera through this key (see [_locate]).
  final _playbackKey = GlobalKey<PlaybackDashboardState>();

  /// The engine whose start the page last handled: a non-identical
  /// instance on a model change is a new replay (the controller
  /// replaces the engine), which fits the track once. See
  /// [_onModelChanged].
  TrackPlayback? _seenPlayback;

  /// The replay tick. Page-owned on purpose (the same rule as the
  /// coverage debounce: the model outlives pages and must never hold a
  /// timer no page listens to): while the engine plays, it advances the
  /// engine with wall-clock deltas and fires the per-tick repaint
  /// channel (`playbackLive`) — the bar, the marker, the trace and the
  /// playback dashboard's follow-camera feed rebuild off it, never the
  /// model.
  Timer? _playbackTimer;
  DateTime? _playbackLastTick;

  /// The largest wall delta one tick may advance the timeline by: a
  /// backgrounded app resumes with hours of unmeasured time, and a
  /// replay must not jump its state as if hours of watching happened.
  static const _playbackTickMaxDelta = Duration(milliseconds: 500);

  void _updatePlaybackTimer() {
    final playing = widget.model.playback?.status == PlaybackStatus.playing;
    if (!playing) {
      _playbackTimer?.cancel();
      _playbackTimer = null;
      _playbackLastTick = null;
      return;
    }
    if (_playbackTimer == null) {
      _playbackLastTick = DateTime.now();
      _playbackTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        _playbackTick,
      );
    }
  }

  void _playbackTick(Timer timer) {
    final playback = widget.model.playback;
    if (playback == null) return; // stop path cancels the timer anyway
    final now = DateTime.now();
    final delta = now.difference(_playbackLastTick ?? now);
    _playbackLastTick = now;
    playback.advance(
        delta > _playbackTickMaxDelta ? _playbackTickMaxDelta : delta);
    widget.model.player.playbackLive.notify();
  }

  /// The play/pause/speed state lives on the live channel (per-tick
  /// concerns never notify the whole model), so the tick timer tracks
  /// the engine's state through it.
  void _onPlaybackLive() {
    if (!mounted) return;
    _updatePlaybackTimer();
  }

  /// The replay's layers, in the recording layers' twin pattern:
  /// mounted with the playback's model notification (the page build
  /// itself), rebuilt per tick via the live channel only — a moving
  /// marker never repaints the fog (which this gate unmounts while the
  /// replay runs anyway). The trace is the played prefix with
  /// the interpolated position at its head (the recording live trace's
  /// look by design: an in-progress line, legible over the bare map),
  /// the marker the course-up
  /// disc the recording marker is, in the trace color — its child's
  /// angle is the course in map-content space, same rule as the
  /// recording marker (flutter_map renders layer children inside the
  /// camera's content rotation, which supplies the camera term on
  /// screen).
  List<Widget> _playbackLayers() {
    return [
      ListenableBuilder(
        listenable: widget.model.player.playbackLive,
        builder: (context, _) {
          final playback = widget.model.playback;
          if (playback == null) {
            return PolylineLayer(polylines: const <Never>[]);
          }
          final played = playback.positions.sublist(
            0,
            math.min(playback.playedIndex + 1, playback.positions.length),
          );
          return PolylineLayer(
            polylines: [
              Polyline(
                points: [...played, playback.position],
                color: recordingTraceColor(widget.model.recordingTint),
                strokeWidth: 4,
              ),
            ],
          );
        },
      ),
      ListenableBuilder(
        listenable: widget.model.player.playbackLive,
        builder: (context, _) {
          final playback = widget.model.playback;
          if (playback == null) {
            return MarkerLayer(markers: const <Never>[]);
          }
          return MarkerLayer(
            markers: [
              Marker(
                point: playback.position,
                width: 44,
                height: 44,
                child: Transform.rotate(
                  key: const ValueKey('playback-marker-rotate'),
                  angle: (playback.course ?? 0) * math.pi / 180,
                  child: Container(
                    key: const ValueKey('playback-marker-disc'),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.surface,
                      border: Border.all(
                        color: recordingTraceColor(
                          widget.model.recordingTint,
                        ),
                        width: 2,
                      ),
                      boxShadow: const [
                        BoxShadow(blurRadius: 4, color: Colors.black38),
                      ],
                    ),
                    child: Icon(
                      Icons.navigation,
                      size: 32,
                      color: recordingTraceColor(
                        widget.model.recordingTint,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ];
  }

  /// The bottom overlay column (selection bar, recording chip and
  /// panel), measured so the follow-camera frames the fix above
  /// it instead of under it — the column grows when the stats panel opens.
  final _bottomColumnKey = GlobalKey();

  /// Pixels the bottom overlay column currently occupies, measured from
  /// the screen bottom (its own height plus the SafeArea inset the column
  /// sits on). Zero until the first layout.
  double bottomOverlap() {
    final box = _bottomColumnKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return 0;
    // The column sits on a SafeArea minimum of 16 that the system inset
    // raises, not adds to.
    final safe = MediaQuery.paddingOf(_bottomColumnKey.currentContext!);
    return box.size.height + math.max(safe.bottom, 16);
  }

  /// The fit-request epoch MapPage handled last (see the import epoch):
  /// a track-tile tap asks for a fit to the tapped track (falling back
  /// to its aggregate when no per-track fit is pending).
  int _seenFitRequestEpoch = 0;

  /// The aggregate-hide epoch last handled (the undo toast fires on a
  /// bump — the fitRequestEpoch pattern).
  int _seenAggregateHideEpoch = 0;

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
    _coverageDebounce?.cancel();
    _playbackTimer?.cancel();
    widget.model.removeListener(_onModelChanged);
    widget.model.player.playbackLive.removeListener(_onPlaybackLive);
    super.dispose();
  }

  /// Whether picking mode was on at the last model change, to detect the
  /// off→on transition (toast + fit) and the pick being cleared (bubble).
  bool _wasMemberPicking = false;

  void _onModelChanged() {
    if (!mounted) return;
    final model = widget.model;
    if (model.memberPicking && !_wasMemberPicking) {
      // Entering picking: say what the mode is, and make sure the whole
      // selection is on screen before the user goes hunting for lanes.
      _toast(AppStrings.ofContext(context).memberPickToast);
      final selected = model.selectedAggregate;
      if (selected != null && selected.points.isNotEmpty) {
        final bounds = LatLngBounds.fromPoints(selected.points);
        final visible = _mapController.camera.visibleBounds;
        final onScreen = visible.contains(bounds.northEast) &&
            visible.contains(bounds.southWest);
        if (!onScreen) {
          _fitWhenSized(
            CameraFit.coordinates(
              coordinates: selected.points,
              padding: _fitPadding,
            ),
          );
        }
      }
    }
    if (model.pickedMemberId == null) _bubbleAt = null;
    _wasMemberPicking = model.memberPicking;
    // The selection bar's hide button fired: offer the undo toast.
    final hideEpoch = model.aggregateHideEpoch;
    if (hideEpoch != _seenAggregateHideEpoch) {
      _seenAggregateHideEpoch = hideEpoch;
      final strings = AppStrings.ofContext(context);
      // Hide-then-show, so a rapid second hide replaces the toast instead
      // of queueing behind it (the showMapToast discipline).
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.areaHiddenToast),
          action: SnackBarAction(
            key: const ValueKey('undo-hide-action'),
            label: strings.undoAction,
            onPressed: () => model.undoLastHide(),
          ),
          // The Material default (4 s): fades away on its own, long enough
          // to tap Undo.
        ),
      );
    }
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
    // A track-tile tap asks for a fit to the tapped track's own points
    // (fitTrackId, consumed here); the fallback — a bare epoch bump —
    // fits the selected aggregate (the plain select path — a map tap —
    // never sets the epoch).
    final fitEpoch = widget.model.fitRequestEpoch;
    if (fitEpoch != _seenFitRequestEpoch) {
      _seenFitRequestEpoch = fitEpoch;
      List<LatLng>? points;
      final fitTrackId = widget.model.fitTrackId;
      widget.model.fitTrackId = null;
      if (fitTrackId != null) {
        for (final t in widget.model.visibleTracks) {
          if (t.meta.id == fitTrackId) {
            points = t.points;
            break;
          }
        }
      } else {
        points = widget.model.selectedAggregate?.points;
      }
      if (points != null && points.isNotEmpty) {
        _fitWhenSized(
          CameraFit.coordinates(
            coordinates: points,
            padding: _fitPadding,
          ),
        );
      }
    }
    // A new replay (the controller replaces the engine instance) fits
    // the whole track once, so the replay starts visible wherever the
    // camera was; the follow-camera takes over from the next tick. The
    // tick timer follows the state here and through the live channel
    // (play/pause ride on it, see [_onPlaybackLive]).
    final playback = widget.model.playback;
    if (!identical(playback, _seenPlayback)) {
      _seenPlayback = playback;
      _updatePlaybackTimer();
      if (playback != null && playback.positions.isNotEmpty) {
        _fitWhenSized(
          CameraFit.coordinates(
            coordinates: playback.positions,
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
    final model = widget.model;
    // In member-picking mode a tap picks one of the colored member lanes
    // instead of (de)selecting the aggregate; a miss exits the mode.
    if (model.memberPicking && model.selectedAnchor != null) {
      _pickMemberAtTap(tap);
      return;
    }
    model.selectAggregateAt(
      tap,
      toleranceMeters: _hitToleranceMeters(tap),
      clearIfMiss: model.selectedAnchor != null,
    );
  }

  // --- Member-picking mode -------------------------------------------------

  /// All member lanes of the current selection at the current zoom
  /// half-step, memoized: lane offsets are in ground meters and change
  /// with the zoom band, like the fog coarsening.
  List<_MemberLane>? _memberLanesCache;
  String? _memberLanesKey;

  List<_MemberLane> _memberLanes() {
    final model = widget.model;
    final ids = model.selectedMemberIds ?? const <String>[];
    if (model.selectedAggregate == null || ids.isEmpty) return const [];
    final zoom = _cameraZoom ?? _mapController.camera.zoom;
    final byId = {for (final t in model.store.tracks) t.id: t};
    final visKey = [
      for (final id in ids) '${id[0]}${byId[id]?.visible == true ? 1 : 0}',
    ].join(',');
    final key = '$_fogZoomStep|${ids.join(',')}|$visKey';
    if (key == _memberLanesKey && _memberLanesCache != null) {
      return _memberLanesCache!;
    }
    _memberLanesKey = key;
    final assignments = model.memberAssignments;
    // Decimate every member first, in lane order: one point list per
    // member drives both the overlap grid and the drawn segments.
    final orderedIds = [
      for (final id in ids)
        if (byId[id] != null && assignments[id] != null) id,
    ]..sort((x, y) => assignments[x]!.lane.compareTo(assignments[y]!.lane));
    final decSegments = <String, List<List<LatLng>>>{};
    final membersPoints = <List<LatLng>>[];
    for (final id in orderedIds) {
      final segs = <List<LatLng>>[];
      for (final seg in splitTrackSegments(model.pointsOf(byId[id]!))) {
        final dec = decimate(seg, _fogLineDecimation());
        if (dec.length >= 2) segs.add(dec);
      }
      decSegments[id] = segs;
      membersPoints.add([for (final s in segs) ...s]);
    }
    // Lane spacing: 3 screen px at the current zoom. Offsets are adaptive
    // per vertex (laneOffsetsPerVertex): a track alone at a vertex stays
    // on its true geometry; overlapping members spread ±0.5, ±1.5, …
    // lanes around it. Two members count as overlapping within ~7.5 px.
    final laneMeters =
        3.0 *
        groundResolution(
          zoom: zoom,
          latitude: _mapController.camera.center.latitude,
        );
    final overlapMeters = 2.5 * laneMeters;
    final lanes = <_MemberLane>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final id = orderedIds[i];
      final segments = <List<LatLng>>[];
      for (final seg in decSegments[id]!) {
        final offsets = laneOffsetsPerVertex(
          seg,
          selfIndex: i,
          membersPoints: membersPoints,
          laneMeters: laneMeters,
          overlapMeters: overlapMeters,
        );
        segments.add(offsetLanePointsPerVertex(seg, offsets));
      }
      lanes.add(_MemberLane(id, assignments[id]!, byId[id]!.visible, segments));
    }
    _memberLanesCache = lanes;
    return lanes;
  }

  /// Screen-px distance from [p] to the segment [a]-[b].
  static double _pxDistToSegment(Offset p, Offset a, Offset b) {
    final abx = b.dx - a.dx, aby = b.dy - a.dy;
    final lenSq = abx * abx + aby * aby;
    var t = lenSq == 0
        ? 0.0
        : (((p.dx - a.dx) * abx + (p.dy - a.dy) * aby) / lenSq).clamp(0.0, 1.0);
    final dx = p.dx - (a.dx + t * abx), dy = p.dy - (a.dy + t * aby);
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Lane candidates for a picking-mode tap at map-local [offset], nearest
  /// first, within [tolerancePx]: (member id, px distance). Hit-tested
  /// against the same offset lane geometry the layer draws, so what the
  /// user aims at is what hits.
  List<(String, double)> _laneCandidatesAt(
    Offset offset, {
    required double tolerancePx,
  }) {
    final camera = _mapController.camera;
    final out = <(String, double)>[];
    for (final lane in _memberLanes()) {
      var best = tolerancePx;
      for (final seg in lane.segments) {
        for (var i = 0; i < seg.length - 1; i++) {
          final d = _pxDistToSegment(
            offset,
            camera.latLngToScreenOffset(seg[i]),
            camera.latLngToScreenOffset(seg[i + 1]),
          );
          if (d < best) best = d;
        }
      }
      if (best < tolerancePx) out.add((lane.id, best));
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }

  /// The tap that last picked, for cycling between near-coincident lanes.
  Offset? _lastPickTap;
  DateTime? _lastPickTapTime;
  List<String> _lastPickCandidateIds = const [];
  int _cycleIndex = 0;

  /// Where the action bubble floats (map-local), set with the pick.
  Offset? _bubbleAt;

  /// The lane under the mouse cursor in picking mode (desktop hover).
  String? _hoveredMemberId;

  void _pickMemberAtTap(LatLng tap) {
    final model = widget.model;
    final offset = _mapController.camera.latLngToScreenOffset(tap);
    final candidates = _laneCandidatesAt(offset, tolerancePx: 24);
    if (candidates.isEmpty) {
      // Tap-away: a miss leaves picking mode back to plain selection.
      _bubbleAt = null;
      model.exitMemberPicking();
      return;
    }
    final now = DateTime.now();
    var index = 0;
    // "Same spot" = within 48 px (past the double-tap slop of 36 px, so a
    // repeated tap is a tap, not a zoom): re-tapping a crossing promotes
    // the next coincident lane; anything farther is a deliberate new aim.
    final sameSpot =
        _lastPickTap != null &&
        (offset - _lastPickTap!).distance < 48 &&
        _lastPickTapTime != null &&
        now.difference(_lastPickTapTime!) < const Duration(seconds: 2);
    final ids = [for (final c in candidates) c.$1];
    if (sameSpot &&
        ids.length > 1 &&
        candidates[1].$2 - candidates[0].$2 < 4 &&
        ids.join() == _lastPickCandidateIds.join()) {
      // A repeated tap where two lanes converge (a crossing): promote the
      // next candidate instead of re-picking the same one.
      index = (_cycleIndex + 1) % candidates.length;
    }
    _lastPickTap = offset;
    _lastPickTapTime = now;
    _lastPickCandidateIds = ids;
    _cycleIndex = index;
    model.pickMember(candidates[index].$1);
    // The bubble anchors itself above the tap point (see _memberBubble),
    // so the spot stays tappable — a repeated tap there cycles coincident
    // lanes instead of hitting the bubble.
    _bubbleAt = offset;
    setState(() {});
  }

  /// Member-picking mode: one parallel lane per member of the selected
  /// aggregate, each in its own assigned tint (see
  /// [AppModel.memberAssignments]) so overlapping tracks read side by side
  /// in different colors. Hidden members stay as dashed grey ghost lanes.
  /// The picked (or, on desktop, hovered) lane glows — a wide translucent
  /// halo under a solid line with a light border. Plain colored lines in
  /// every fog style: the mode is temporary and must read as "the tracks
  /// themselves".
  List<Widget> _memberPickLayers() {
    final model = widget.model;
    if (model.selectedAggregate == null) return const [];
    final picked = model.pickedMemberId;
    final hovered = _hoveredMemberId;
    final ghosts = <Polyline>[];
    final lanes = <Polyline>[];
    final glow = <Polyline>[];
    for (final lane in _memberLanes()) {
      final color =
          exploredAreaColor(lane.assignment.tintKey).withValues(alpha: 1);
      if (!lane.visible) {
        for (final seg in lane.segments) {
          ghosts.add(Polyline(
            points: seg,
            strokeWidth: 3,
            color: Colors.grey.withValues(alpha: 0.55),
            pattern: StrokePattern.dashed(segments: [6.0, 6.0]),
          ));
        }
        continue;
      }
      final hot = lane.id == picked || lane.id == hovered;
      for (final seg in lane.segments) {
        if (hot) {
          glow.add(Polyline(
            points: seg,
            strokeWidth: 11,
            color: color.withValues(alpha: 0.35),
          ));
          lanes.add(Polyline(
            points: seg,
            strokeWidth: 4.5,
            color: color,
            borderStrokeWidth: lane.id == picked ? 1.5 : 0,
            borderColor: Colors.white70,
          ));
        } else {
          lanes.add(Polyline(
            points: seg,
            strokeWidth: 4,
            color: color.withValues(alpha: 0.9),
          ));
        }
      }
    }
    final all = [...ghosts, ...lanes, ...glow];
    if (all.isEmpty) return const [];
    return [PolylineLayer(polylines: all)];
  }

  /// The action bubble for the picked member track, floating on the map at
  /// the tap that picked it: the track's name in its lane color, with
  /// labeled actions — hide this track / hide the others for a visible
  /// pick, show it again for a ghost.
  Widget _memberBubble() {
    final model = widget.model;
    final id = model.pickedMemberId;
    final pos = _bubbleAt;
    if (id == null || pos == null) return const SizedBox.shrink();
    final matches = model.store.tracks.where((t) => t.id == id);
    if (matches.isEmpty) return const SizedBox.shrink();
    final t = matches.first;
    final strings = AppStrings.ofContext(context);
    final scheme = Theme.of(context).colorScheme;
    final color = exploredAreaColor(
      model.memberAssignments[id]?.tintKey ?? defaultTintKey,
    ).withValues(alpha: 1);
    // Clamp horizontally inside the map's bounds; anchor vertically by
    // the bottom edge 10 px above the tap point (so the card sizes to its
    // content and the gap is constant), flipping below the tap near the
    // top edge. The leader tip points at the tap.
    final size = _mapController.camera.size;
    const bubbleW = 240.0;
    const gap = 10.0;
    const maxBubbleH = 170.0; // tallest content (two buttons), for the flip
    final dx =
        pos.dx.clamp(4.0, math.max(size.width - bubbleW - 4, 4)).toDouble();
    final above = pos.dy > maxBubbleH + gap;
    return Positioned(
      key: const ValueKey('member-bubble'),
      left: dx,
      width: bubbleW,
      bottom: above ? size.height - pos.dy + gap : null,
      top: above ? null : pos.dy + gap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!above) _leaderTip(scheme.surface, pos.dx - dx, down: false),
          Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            color: scheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: t.visible ? color : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (t.visible) ...[
                    TextButton(
                      key: const ValueKey('member-bubble-hide'),
                      onPressed: () => model.hidePickedMember(),
                      child: Text(strings.memberPickHide),
                    ),
                    TextButton(
                      key: const ValueKey('member-bubble-hide-others'),
                      onPressed: () => model.showOnlyPickedMember(),
                      child: Text(strings.memberPickHideOthers),
                    ),
                  ] else
                    TextButton(
                      key: const ValueKey('member-bubble-show'),
                      onPressed: () => model.showPickedMember(),
                      child: Text(strings.memberPickShow),
                    ),
                ],
              ),
            ),
          ),
          if (above) _leaderTip(scheme.surface, pos.dx - dx, down: true),
        ],
      ),
    );
  }

  /// The leader triangle under (or above, when flipped) the bubble card,
  /// its tip at the tap x clamped into the card's width.
  Widget _leaderTip(Color color, double tipOffsetX, {required bool down}) {
    const bubbleW = 240.0;
    return SizedBox(
      height: 8,
      child: Row(
        children: [
          SizedBox(
              width: tipOffsetX.clamp(8.0, bubbleW - 24).toDouble() - 8),
          CustomPaint(
            size: const Size(16, 8),
            painter: _LeaderTipPainter(color, down: down),
          ),
        ],
      ),
    );
  }

  /// The selected aggregate's highlight, in the active fog style so the
  /// selection reads the same language the map is drawn in: boosted-
  /// opacity circles, solid tinted lines, or full-strength ink strokes.
  List<Widget> _selectionHighlightLayers() {
    final selected = widget.model.selectedAggregate;
    if (selected == null) return const [];
    final key = widget.model.aggregateTintKeys[selected.anchorId];
    final tint = exploredAreaColor(key ?? defaultTintKey);
    switch (widget.model.fogStyle) {
      case 'polyline':
        return [
          PolylineLayer(polylines: [
            for (final seg in splitTrackSegments(selected.points))
              if (decimate(seg, _fogLineDecimation()).length >= 2)
                Polyline(
                  points: decimate(seg, _fogLineDecimation()),
                  strokeWidth: 4.5,
                  color: tint.withValues(alpha: 1),
                  borderStrokeWidth: 1,
                  borderColor: Colors.black38,
                ),
          ]),
        ];
      case 'ink':
        return [
          PolylineLayer(polylines: [
            for (final seg in splitTrackSegments(selected.points))
              for (final pass in inkStrokes(
                decimate(seg, _fogLineDecimation()),
                passCount: inkPassWidthFactors.length,
                minRunLength: inkBaseRunLength,
                maxStripsPerTrack: inkMaxStripsPerTrack,
              ))
                for (final s in pass.strips)
                  Polyline(
                    points: s.run,
                    strokeWidth: inkWidthMeters * pass.width * _pxPerMeter(),
              color: inkColorFor(key ?? defaultTintKey)
                  .withValues(alpha: 1),
                  ),
          ]),
        ];
      default:
        final highlight =
            tint.withValues(alpha: (tint.a + 0.55).clamp(0.0, 1.0));
        return [
          CircleLayer(circles: [
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
          ]),
        ];
    }
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

  /// The recording marker: at the last accepted fix. The child's angle is
  /// the course in *map-content* space: flutter_map renders MarkerLayer
  /// children inside the camera's content rotation (`MobileLayerTransformer`
  /// wraps the layer), which (with the map content itself) composes with
  /// the camera rotation on screen. So the nose lands at geographic
  /// course + camera rotation on screen — straight up exactly while the
  /// camera rides the course, and still along the direction of travel
  /// after a gesture releases the follow (or in north-up mode) — without
  /// this widget adding the rotation itself, which would count it twice.
  /// A fix without a heading and no bearing yet renders unrotated.
  ///
  /// The subtree mounts with the session itself (a boundary always
  /// notifies the model and rebuilds this page), while the position is
  /// read *inside* the per-fix builder: fixes notify the recording-live
  /// channel only, never the model, so a page build must never decide
  /// the marker's existence or position. Reading either of those at build
  /// time mounts nothing until an incidental notify happens to rebuild
  /// the page (the session's very first frame predates the first fix) and
  /// then freezes the marker at whatever fix that rebuild caught — the
  /// camera rides on with the live fixes and the stale marker slides off
  /// the screen. Until the first fix the builder renders an empty layer.
  /// Gesture rotations turn the nose with the content in the same frame
  /// by construction.
  List<Widget> _recordingMarkers() {
    final session = widget.model.recording;
    if (session == null) return const [];
    return [
      ListenableBuilder(
        listenable: widget.model.recordingLive,
        builder: (context, _) {
          final lat = session.currentLat;
          final lon = session.currentLon;
          if (lat == null || lon == null) {
            return const MarkerLayer(markers: []);
          }
          return MarkerLayer(
            markers: [
              Marker(
                point: LatLng(lat, lon),
                width: 44,
                height: 44,
                child: Transform.rotate(
                  key: const ValueKey('recording-marker-rotate'),
                  angle: (session.currentCourse ?? 0) * math.pi / 180,
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
          );
        },
      ),
    ];
  }

  /// Re-arms whichever follow-camera is active and re-centers on its
  /// fix/cursor — the pill's course-up activation takes the camera along
  /// (a released follow would otherwise leave the panned-away view while
  /// only the setting changed). Mirrors [_locate]'s dispatch.
  /// True while either follow-camera (the session's or the replay's) is
  /// armed on its point — the pill's locate slot then takes a break, since
  /// the camera is already locked on what the button would re-center on.
  bool get _followArmed =>
      (_dashboardKey.currentState?.followArmed ?? false) ||
      (_playbackKey.currentState?.followArmed ?? false);

  void _rearmActiveFollow() {
    if (widget.model.isRecording) {
      _dashboardKey.currentState?.rearmFollow();
    } else if (widget.model.playback != null) {
      _playbackKey.currentState?.rearmFollow();
    }
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
  /// The whole attempt is bracketed by [_locating], so the pill's locate
  /// button turns into a spinner for as long as the fix takes. Re-entrant taps
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
    // On a platform without a location plugin (desktop Linux) there is no
    // GPS locate — but while a replay runs, the pill's last slot is a
    // follow button instead: re-arm the follow on the replay's cursor,
    // re-centering on the moving marker after a pan released it.
    if (widget.model.playback != null) {
      _playbackKey.currentState?.rearmFollow();
      return;
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

  /// The fog overlay in the two line styles: per aggregate, its decimated
  /// track segments as uniform polylines in the aggregate tint — raised
  /// alpha, since a thin line needs more opacity than the circles to read.
  /// The ink style draws the same geometry as layered meter-sized ink
  /// passes (bleed under core), converted to pixels via the current zoom.
  List<Polyline> _buildFogLines(List<MapTrack> tracks) {
    final tintKeys = widget.model.aggregateTintKeys;
    final ink = widget.model.fogStyle == 'ink';
    // Ground meters to screen pixels at the current camera: the ink
    // strokes are sized in meters (like the fog circles), the polyline
    // style stays a fixed screen-space width.
    final pxPerMeter = _pxPerMeter();
    final out = <Polyline>[];
    for (final a in widget.model.aggregates) {
      final tint = exploredAreaColor(tintKeys[a.anchorId] ?? defaultTintKey);
      final key = '${a.anchorId}@$_fogCellSize';
      var passes = _inkPassesCache[key];
      if (passes == null) {
        passes = [
          for (final seg in splitTrackSegments(a.points))
            ...inkStrokes(
              decimate(seg, _fogLineDecimation()),
              passCount: inkPassWidthFactors.length,
              minRunLength: inkBaseRunLength,
              maxStripsPerTrack: inkMaxStripsPerTrack,
            ),
        ];
        _inkPassesCache[key] = passes;
      }
      if (!ink) {
        for (final seg in splitTrackSegments(a.points)) {
          final pts = decimate(seg, _fogLineDecimation());
          if (pts.length >= 2) {
            out.add(Polyline(points: pts, strokeWidth: 3.5, color: tint));
          }
        }
      } else {
        for (final pass in passes) {
          for (final s in pass.strips) {
            out.add(Polyline(
              points: s.run,
              strokeWidth: inkWidthMeters * pass.width * pxPerMeter,
              color: inkColorFor(tintKeys[a.anchorId] ?? defaultTintKey)
                  .withValues(alpha: pass.alpha),
            ));
          }
        }
      }
    }
    return out;
  }

  /// Cache of ink stroke passes per aggregate @ fog band: recomputed only
  /// on band crossings (like the circle centers), reused across pans and
  /// same-band zooms. Pass widths are in meters and converted to pixels
  /// at paint time, so a 0.5-zoom-step refresh needs no recompute.
  final _inkPassesCache = <String, List<InkPass>>{};

  /// Ground meters to screen pixels at the current camera (1.0 when the
  /// camera has no size yet, e.g. first layout).
  double _pxPerMeter() {
    final zoom = _cameraZoom;
    if (zoom == null) return 1.0;
    return 1.0 /
        groundResolution(
          zoom: zoom,
          latitude: _mapController.camera.center.latitude,
        );
  }

  /// The camera zoom at the last map event, or null before the first
  /// one; drives the meter-to-pixel conversion of the ink style.
  double? _cameraZoom;

  /// Band-aware decimation for the fog line styles: keep every k-th
  /// point, where k is the current fog band's power-of-two coarsening —
  /// the same contract the circles ride, so cost decays as the view
  /// zooms out.
  int _fogLineDecimation() {
    final k = (_fogCellSize / baseCellSizeMeters).round();
    return k < 1 ? 1 : k;
  }

  /// The fog overlay in the two line styles...

  /// Unlocked road corridors: the matched sub-polylines persisted on each
  /// visible track, drawn fat and translucent in the track's aggregate
  /// tint so corridors and their circles read as one overlay. A way
  /// unlocked by several tracks draws once (the corridors usually
  /// coincide; double-drawing would double-darken the shared stretch).
  /// flutter_map culls off-screen polylines and simplifies them per zoom;
  /// LOD variants are deferred until catalog scale demands them.
  /// The unvisited roads of the settled viewport: every way's
  /// unmatched stretches as dashed polylines in a neutral ink that
  /// reads as "background target" - deliberately outside the
  /// exploration tint family, since these are the roads nothing has
  /// discovered yet. Dashes keep them distinct from the solid dark
  /// corridors drawn over them.
  List<Polyline> _buildUnvisitedPolylines() {
    return [
      for (final way in widget.model.viewportOverlay)
        for (final stretch in way.$2)
          if (stretch.length > 1)
            Polyline(
              points: stretch,
              strokeWidth: 3,
              color: Colors.blueGrey.withValues(alpha: 0.55),
              pattern: StrokePattern.dashed(segments: [8, 6]),
            ),
    ];
  }

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
    final unvisited = _buildUnvisitedPolylines();
    return Scaffold(
      // No app bar: the labeled actions live on a compact floating
      // toolbar that hugs its content at the top-right corner, so the
      // map map keeps rendering behind it instead of being pushed down
      // by a full-width bar.
      endDrawerEnableOpenDragGesture: false,
      endDrawer: TrackDrawer(model: widget.model),
      body: Stack(
        children: [
          // Hover in picking mode previews the lane under the cursor
          // (desktop; a no-op on touch, where there is no hover).
          MouseRegion(
            onHover: _onPickingHover,
            onExit: (_) {
              if (_hoveredMemberId != null) {
                setState(() => _hoveredMemberId = null);
              }
            },
            child: FlutterMap(
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
              // The unvisited-roads overlay right above the tiles and
              // below the fog: undiscovered roads are background hints,
              // and everything discovered paints over them.
              if (unvisited.isNotEmpty) PolylineLayer(polylines: unvisited),
              // The fog-of-war overlay, absent while a replay runs (and
              // back on close): circles by default, or one of the line
              // styles when Settings picks one — same replay gate either
              // way.
              if (widget.model.playback == null)
                switch (widget.model.fogStyle) {
                  'polyline' => PolylineLayer(
                      polylines: _buildFogLines(mapTracks),
                    ),
                  'ink' => PolylineLayer(
                      polylines: _buildFogLines(mapTracks),
                    ),
                  _ => CircleLayer(circles: _buildFogCircles(mapTracks)),
                },
              // Unlocked road corridors (fog-of-war for streets), above
              // the circles so the corridor reads on top of the blobs.
              if (corridors.isNotEmpty) PolylineLayer(polylines: corridors),
              // The selected aggregate's highlight, above corridors so the
              // selection reads on top of the overlay — or, in
              // member-picking mode, one colored polyline per member track
              // (the picked one glowing) in place of the highlight.
              if (widget.model.memberPicking)
                ..._memberPickLayers()
              else if (widget.model.selectedAnchor != null)
                ..._selectionHighlightLayers(),
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
              // The replay's trace and marker, above everything — while
              // a replay runs the fog circles are unmounted (the layers'
              // gate above), so the trace rides the bare map plus the
              // corridors; the follow-camera belongs to the playback
              // dashboard below.
              if (widget.model.playback != null) ..._playbackLayers(),
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
          ),
          // The edge control pill (rotation mode, zoom in/out, locate) on
          // the configured edge (settings), vertically centered in the
          // free band between the toolbar and the bottom. SafeArea keeps
          // the band inset-aware; the right side still starts below the
          // toolbar band, so the two never overlap on narrow screens (the
          // toolbar is centered and can reach the edges) — the left side
          // has no toolbar there.
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
              child: Center(
                child: MapControlPill(
                  controller: _mapController,
                  model: widget.model,
                  showLocate: widget.locationSupported && !_followArmed,
                  locating: _locating,
                  onLocate: _locate,
                  onRearmFollow: _rearmActiveFollow,
                  followArmed: _followArmed,
                ),
              ),
            ),
          ),
          // The record cluster (record / pause / resume, with Stop above
          // once the session runs) on the edge *opposite* the pill,
          // vertically centered — big labeled buttons away from the other
          // controls, sized for a handlebar mount. Only where the platform
          // has a location plugin: a record button on a GPS-less platform
          // would be a dead button (its slot also stays hidden until a real
          // fix arrived, see `RecordCluster`).
          if (widget.locationSupported && widget.model.playback == null)
            Positioned(
              top: 0,
              bottom: 0,
              left: widget.model.zoomSliderSide == 'left' ? null : 12,
              right: widget.model.zoomSliderSide == 'left' ? 12 : null,
              child: SafeArea(
                minimum: EdgeInsets.only(
                  top: widget.model.zoomSliderSide == 'left'
                      ? kToolbarHeight + 24
                      : 16,
                  bottom: 16,
                ),
                child: Center(
                  child: RecordCluster(
                    model: widget.model,
                    gpsWorking: _gpsWorking,
                  ),
                ),
              ),
            ),
          // Compact floating toolbar at the top, centered across the
          // map's top edge instead of a full-width app bar — the only
          // overlay up there now; the selection bar and the recording
          // chip live in the bottom column below. While a session runs
          // the bar's center is the session's speed (see TopToolbar and
          // RecordingSpeedSegment in map_actions.dart).
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
          // One non-overlapping vertical column at the bottom: the selection
          // bar while an aggregate is selected, then the recording chip and
          // stats while a session runs, then the playback bar, ending at
          // the bottom edge. One column, so none of them can overlap on
          // narrow screens. (Locate and record live in the edge clusters
          // now — see the pill and record cluster above.)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              minimum: const EdgeInsets.only(bottom: 16),
              child: Column(
                key: _bottomColumnKey,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The unvisited-roads chip: first in the column so it
                  // never covers an action button, and hidden without a
                  // region or while the overlay setting is off (see
                  // RoadCoverageChip).
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: RoadCoverageChip(model: widget.model),
                    ),
                  ),
                  // The aggregate selection's actions pill: hide, color,
                  // fit, dismiss — a temporary state at the bottom of the
                  // map, above the recording chip and the action stack.
                  if (widget.model.selectedAnchor != null) ...[
                    SelectionBar(
                      // Keyed by the anchor so a different selection
                      // starts with the member strip collapsed.
                      key: ValueKey(widget.model.selectedAnchor),
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
                          setState(() => widget.model.clearSelection()),
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
                    bottomOverlap: bottomOverlap,
                    onFollowChanged: () => setState(() {}),
                  ),
                  // The playback bar ends the column: like the recording
                  // chip it is measured into [bottomOverlap], so the
                  // shared follow-camera frames a replay marker above
                  // it. Never mounted next to a recording chip (the
                  // model stops a replay when a session starts, the
                  // menu gates starting one during a session).
                  PlaybackDashboard(
                    key: _playbackKey,
                    model: widget.model,
                    mapController: _mapController,
                    bottomOverlap: bottomOverlap,
                    onFollowChanged: () => setState(() {}),
                  ),
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
          // The picked member track's action bubble, topmost on the map.
          _memberBubble(),
        ],
      ),
    );
  }

  /// Desktop hover in picking mode: glow the lane under the cursor.
  void _onPickingHover(PointerHoverEvent event) {
    if (!widget.model.memberPicking) return;
    final candidates = _laneCandidatesAt(event.localPosition, tolerancePx: 12);
    final id = candidates.isEmpty ? null : candidates.first.$1;
    if (id != _hoveredMemberId) setState(() => _hoveredMemberId = id);
  }
}
