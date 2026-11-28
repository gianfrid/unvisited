import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../aggregate/member_colors.dart' show MemberColorAssignment;
import '../geo.dart' show haversineMeters;
import '../l10n/app_strings.dart';
import '../playback/track_playback.dart';
import '../storage/track_store.dart' show StoredPhoto;
import '../recording/recording_session.dart';
import '../tile_source.dart';
import 'app_model.dart';
import 'fog_of_war.dart';
import 'ink_stroke.dart';
import 'lane_offset.dart';
import 'map_actions.dart';
import 'map_controls.dart';
import 'photo_preview.dart';
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

/// One member's geometry in member-picking mode: as drawn and
/// hit-tested — decimated, segment-split, on its true geometry. The
/// sideways lane offset exists only in a tap's reveal window (see
/// MapPage._revealLanes); plain lines never spread.
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

class _MapPageState extends State<MapPage> with SingleTickerProviderStateMixin {
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
        // The picking-mode lanes convert ground meters to pixels per zoom
        // half-step. The ink style does not: its strokes are meter-sized
        // and flutter_map converts them at paint time.
        dirty = widget.model.memberPicking;
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

  /// The camera zoom quantized to half-steps, for the member-picking
  /// reveal lanes: their lane spacing converts from ground meters to
  /// pixels with the current zoom, so it refreshes twice per zoom level.
  double _fogZoomStep = 0.0;

  /// True while a locate attempt is in flight. Acquiring a fix takes
  /// seconds (longer on a cold GPS), so the button shows a spinner and
  /// ignores further taps instead of looking dead.
  bool _locating = false;

  /// The last located fix, shown as a "you are here" marker. Ephemeral
  /// UI state: cleared when the user pans away from it (see the map event
  /// listener) so it never points at a spot the user has left behind.
  LatLng? _locatedPosition;

  /// The freshest fix obtained this run — the silent startup poll or a
  /// Locate — never cleared by panning. Distinct from [_locatedPosition]
  /// (whose pan-drop rule keeps the marker honest): a photo taken after
  /// panning still tags the place the user actually is. A photo's position
  /// is the session's live fix while recording, else this one.
  LatLng? _latestFix;

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

  /// The replay tick, vsync-driven. Page-owned on purpose (the same rule
  /// as the coverage debounce: the model outlives pages and must never
  /// hold a timer no page listens to): while the engine plays, the ticker
  /// fires once per frame and advances the engine with wall-clock deltas,
  /// then fires the per-tick repaint channel (`playbackLive`) — the bar,
  /// the marker, the trace and the playback dashboard's follow-camera
  /// feed rebuild off it, never the model. A ticker rather than a fixed
  /// `Timer.periodic`: at 32x/64x a 20 fps timer moved the cursor 1.6–3.2
  /// s of timeline per frame, so the marker visibly jumped segment to
  /// segment; at display refresh the steps stay small and even.
  late final AnimationController _playbackTicker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..addListener(_playbackTick);
  DateTime? _playbackLastTick;

  /// The largest wall delta one tick may advance the timeline by: a
  /// backgrounded app resumes with hours of unmeasured time (and vsync
  /// stops while backgrounded), and a replay must not jump its state as
  /// if hours of watching happened.
  static const _playbackTickMaxDelta = Duration(milliseconds: 500);

  void _updatePlaybackTicker() {
    final playing = widget.model.playback?.status == PlaybackStatus.playing;
    if (!playing) {
      if (_playbackTicker.isAnimating) _playbackTicker.stop();
      _playbackLastTick = null;
      return;
    }
    if (!_playbackTicker.isAnimating) {
      _playbackLastTick = DateTime.now();
      _playbackTicker.repeat();
    }
  }

  void _playbackTick() {
    final playback = widget.model.playback;
    if (playback == null) return; // stop path stops the ticker anyway
    final now = DateTime.now();
    final delta = now.difference(_playbackLastTick ?? now);
    _playbackLastTick = now;
    playback.advance(
        delta > _playbackTickMaxDelta ? _playbackTickMaxDelta : delta);
    widget.model.player.playbackLive.notify();
  }

  /// The play/pause/speed state lives on the live channel (per-tick
  /// concerns never notify the whole model), so the tick ticker tracks
  /// the engine's state through it.
  void _onPlaybackLive() {
    if (!mounted) return;
    _updatePlaybackTicker();
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
    _playbackTicker.dispose();
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
    if (!model.memberPicking) {
      // Leaving picking mode drops the reveal with it: the spread
      // window belongs to the mode's tap, not to the selection.
      _revealTap = null;
      _revealIds = const [];
      _revealLanesKey = null;
    }
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
          // Undo rides the default 4 s fade. Without this, SnackBars
          // with an action persist until tapped (Flutter 3.47's default:
          // `persist ?? action != null`), so the toast would never
          // dismiss on its own.
          persist: false,
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
    // tick ticker follows the state here and through the live channel
    // (play/pause ride on it, see [_onPlaybackLive]).
    final playback = widget.model.playback;
    if (!identical(playback, _seenPlayback)) {
      _seenPlayback = playback;
      _updatePlaybackTicker();
      if (playback != null && playback.positions.isNotEmpty) {
        _fitWhenSized(
          CameraFit.coordinates(
            coordinates: playback.positions,
            padding: _fitPadding,
          ),
        );
      }
    }
    // A session starting takes over map taps: cancel any pending
    // photo reposition rather than leave a mode nothing will answer.
    if (widget.model.isRecording && _repositioningPhoto != null) {
      _repositioningPhoto = null;
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

  /// The photo currently being repositioned (the preview's Reposition
  /// action armed this): the next map tap sets its position. Null
  /// otherwise. Cleared when a recording session starts — the recording
  /// UI owns map taps then.
  StoredPhoto? _repositioningPhoto;

  void _onMapTap(LatLng tap) {
    // Reposition mode first: the next tap is the photo's new position,
    // not an aggregate selection.
    final repositioning = _repositioningPhoto;
    if (repositioning != null) {
      setState(() => _repositioningPhoto = null);
      unawaited(widget.model.repositionPhoto(repositioning, tap));
      return;
    }
    if (widget.model.isRecording) return; // the recording UI owns taps then
    final model = widget.model;
    // In member-picking mode a tap picks one of the colored member lanes
    // instead of (de)selecting the aggregate; a miss exits the mode.
    if (model.memberPicking && model.selectedAnchor != null) {
      _pickMemberAtTap(tap);
      return;
    }
    // A photo pin wins over aggregate selection: its tap opens the
    // preview (flutter_map's gesture layer sits above marker children,
    // so pins are not individually tappable — the map tap with the same
    // tolerance is the pin's tap).
    final photo = _nearestPhoto(tap);
    if (photo != null) {
      _showPhotoPreview(photo);
      return;
    }
    model.selectAggregateAt(
      tap,
      toleranceMeters: _hitToleranceMeters(tap),
      clearIfMiss: model.selectedAnchor != null,
    );
  }

  // --- Member-picking mode -------------------------------------------------

  /// Every member of the current selection as plain lines on their true
  /// geometry, memoized on the fog band and membership: no lane
  /// spreading, no overlap grid. Spreading every member's full geometry
  /// through per-vertex offsets was the mode's cost with many members —
  /// and overlapping members are indistinguishable on their shared
  /// ground anyway. The spread appears only through a tap's reveal
  /// (see [_revealLanes]).
  List<_MemberLane>? _plainLanesCache;
  String? _plainLanesKey;

  List<_MemberLane> _plainMemberLanes() {
    final model = widget.model;
    final ids = model.selectedMemberIds ?? const <String>[];
    if (model.selectedAggregate == null || ids.isEmpty) return const [];
    final byId = {for (final t in model.store.tracks) t.id: t};
    final visKey = [
      for (final id in ids) '${id[0]}${byId[id]?.visible == true ? 1 : 0}',
    ].join(',');
    final key = '$_fogCellSize|${ids.join(',')}|$visKey';
    final cached = _plainLanesCache;
    if (key == _plainLanesKey && cached != null) return cached;
    _plainLanesKey = key;
    final assignments = model.memberAssignments;
    final lanes = <_MemberLane>[];
    for (final id in ids) {
      final t = byId[id];
      final assignment = assignments[id];
      if (t == null || assignment == null) continue;
      final segments = <List<LatLng>>[];
      for (final seg in splitTrackSegments(model.pointsOf(t))) {
        final dec = decimate(seg, _fogLineDecimation());
        if (dec.length >= 2) segments.add(dec);
      }
      lanes.add(_MemberLane(id, assignment, t.visible, segments));
    }
    _plainLanesCache = lanes;
    return lanes;
  }

  /// The reveal: the members a picking tap found passing one spot, and
  /// the tap itself. Set when a tap meets more than one member within
  /// its tolerance — exactly those members, and only they, draw as
  /// spread lanes in a ±500 m window around the tap; everything else
  /// stays plain. A single-member tap picks directly and clears it.
  /// Cleared when picking mode ends (see [_onModelChanged]).
  LatLng? _revealTap;
  List<String> _revealIds = const [];

  /// The revealed spread lanes for [_revealTap] / [_revealIds], memoized:
  /// lane spacing is in ground meters and changes with the zoom band,
  /// like the fog coarsening. The window keeps the cost O(window), not
  /// O(member).
  List<_MemberLane>? _revealLanesCache;
  String? _revealLanesKey;

  static const _revealWindowMeters = 500.0;

  List<_MemberLane> _revealLanes() {
    final tap = _revealTap;
    if (tap == null || _revealIds.isEmpty) return const [];
    final model = widget.model;
    final byId = {for (final t in model.store.tracks) t.id: t};
    final zoom = _cameraZoom ?? _mapController.camera.zoom;
    final key = [
      '$_fogZoomStep',
      '$_fogCellSize',
      tap.latitude,
      tap.longitude,
      _revealIds.join(','),
      for (final id in _revealIds)
        '${id[0]}${byId[id]?.visible == true ? 1 : 0}',
    ].join('|');
    final cached = _revealLanesCache;
    if (key == _revealLanesKey && cached != null) return cached;
    _revealLanesKey = key;
    final assignments = model.memberAssignments;
    final orderedIds = [
      for (final id in _revealIds)
        if (byId[id] != null && assignments[id] != null) id,
    ]..sort((x, y) => assignments[x]!.lane.compareTo(assignments[y]!.lane));
    // Each involved member's local stretch: the segment whose nearest
    // point is closest to the tap, windowed ±500 m along it. Paired by
    // id (not a parallel list) so a member missing from the plain lanes
    // cannot shift another member's window.
    final plainById = {for (final l in _plainMemberLanes()) l.id: l};
    final windowsById = <String, List<LatLng>>{};
    for (final id in orderedIds) {
      final lane = plainById[id];
      if (lane == null) continue;
      List<LatLng>? bestSeg;
      var bestD = double.infinity;
      for (final seg in lane.segments) {
        for (final p in seg) {
          final d = haversineMeters(
              p.latitude, p.longitude, tap.latitude, tap.longitude);
          if (d < bestD) {
            bestD = d;
            bestSeg = seg;
          }
        }
      }
      windowsById[id] = bestSeg == null
          ? const <LatLng>[]
          : laneWindow(bestSeg, tap, windowMeters: _revealWindowMeters);
    }
    // Lane spacing: 3 screen px at the current zoom. Offsets are adaptive
    // per vertex (laneOffsetsPerVertex): a track alone at a vertex stays
    // on its true geometry; overlapping members spread ±0.5, ±1.5, …
    // lanes around it. Two members count as overlapping within ~7.5 px.
    final laneMeters = 3.0 *
        groundResolution(
          zoom: zoom,
          latitude: _mapController.camera.center.latitude,
        );
    final overlapMeters = 2.5 * laneMeters;
    final lanes = <_MemberLane>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final id = orderedIds[i];
      final win = windowsById[id] ?? const <LatLng>[];
      final plain = plainById[id]!;
      if (win.length < 2) {
        // A stub window has nothing to spread; the member stays as its
        // plain line (drawn separately).
        lanes.add(_MemberLane(
            id, assignments[id]!, plain.visible, const []));
        continue;
      }
      final offsets = laneOffsetsPerVertex(
        win,
        selfIndex: i,
        membersPoints: [for (final id in orderedIds) windowsById[id] ?? const <LatLng>[]],
        laneMeters: laneMeters,
        overlapMeters: overlapMeters,
      );
      lanes.add(_MemberLane(id, assignments[id]!, plain.visible,
          [offsetLanePointsPerVertex(win, offsets)]));
    }
    _revealLanesCache = lanes;
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
  /// against the same plain geometry the layer draws, so what the
  /// user aims at is what hits.
  List<(String, double)> _laneCandidatesAt(
    Offset offset, {
    required double tolerancePx,
  }) {
    final camera = _mapController.camera;
    final out = <(String, double)>[];
    for (final lane in _plainMemberLanes()) {
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
    // The reveal: only a spot several members pass shows them spread —
    // a single-member point needs nothing beyond its plain line.
    if (ids.length > 1) {
      _revealTap = tap;
      _revealIds = ids;
    } else {
      _revealTap = null;
      _revealIds = const [];
    }
    model.pickMember(candidates[index].$1);
    // The bubble anchors itself above the tap point (see _memberBubble),
    // so the spot stays tappable — a repeated tap there cycles coincident
    // lanes instead of hitting the bubble.
    _bubbleAt = offset;
    setState(() {});
  }

  /// Member-picking mode: every member of the selected aggregate as a
  /// plain line on its true geometry, each in its own assigned tint
  /// (see [AppModel.memberAssignments]) — overlapping members read as
  /// one line, their shared ground being indistinguishable anyway.
  /// Where a tap finds several members passing one spot, exactly those
  /// reveal as parallel spread lanes in a ±500 m window around the tap
  /// (see [_revealLanes]). Hidden members stay as dashed grey ghost
  /// lines. The picked (or, on desktop, hovered) revealed lane glows —
  /// a wide translucent halo under a solid line with a light border.
  /// Plain colored lines in every fog style: the mode is temporary and
  /// must read as "the tracks themselves".
  List<Widget> _memberPickLayers() {
    final model = widget.model;
    if (model.selectedAggregate == null) return const [];
    final picked = model.pickedMemberId;
    final hovered = _hoveredMemberId;
    final ghosts = <Polyline>[];
    final lanes = <Polyline>[];
    final glow = <Polyline>[];
    void drawPlain(_MemberLane lane, {required bool revealedWindow}) {
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
        return;
      }
      // The picked member glows exactly once: in its reveal window when
      // the tap revealed one, on its plain line otherwise (a direct
      // single-member pick must not look identical to an unpicked lane).
      // Hover glows only revealed windows — plain overlaps are not
      // spread, so a hover there would glow an ambiguous spot.
      final hot = revealedWindow
          ? (lane.id == picked || lane.id == hovered)
          : (lane.id == picked && !_revealIds.contains(lane.id));
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

    for (final lane in _plainMemberLanes()) {
      drawPlain(lane, revealedWindow: false);
    }
    for (final lane in _revealLanes()) {
      drawPlain(lane, revealedWindow: true);
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

  /// The photo whose pin is within tap tolerance of [tap], nearest first,
  /// or null. Same tolerance as aggregate selection (~24 screen px).
  StoredPhoto? _nearestPhoto(LatLng tap) {
    StoredPhoto? best;
    var bestDist = _hitToleranceMeters(tap);
    for (final p in widget.model.photos) {
      final d = const Distance().distance(tap, LatLng(p.lat, p.lon));
      if (d <= bestDist) {
        best = p;
        bestDist = d;
      }
    }
    return best;
  }

  /// The selected aggregate's highlight, in the active fog style so the
  /// selection reads the same language the map is drawn in: boosted-
  /// opacity circles, solid tinted lines, or full-strength ink strokes.
  /// Line styles dedup across the aggregate's own members (a fresh
  /// claim grid — the highlight shows the full selected extent over
  /// *other* aggregates' fog, so it never drops ground they cover);
  /// the circles already coalesce the whole selection per cell.
  List<Widget> _selectionHighlightLayers() {
    final selected = widget.model.selectedAggregate;
    if (selected == null) return const [];
    final key = widget.model.aggregateTintKeys[selected.anchorId];
    final tint = exploredAreaColor(key ?? defaultTintKey);
    switch (widget.model.fogStyle) {
      case 'polyline':
        final seen = <(int, int), LatLng>{};
        return [
          PolylineLayer(polylines: [
            for (final run in dedupeSegments(
              splitTrackSegments(selected.points),
              seen: seen,
              cellSizeMeters: _fogCellSize,
            ))
              if (decimate(run, _fogLineDecimation()).length >= 2)
                Polyline(
                  points: decimate(run, _fogLineDecimation()),
                  strokeWidth: 4.5,
                  color: tint.withValues(alpha: 1),
                  borderStrokeWidth: 1,
                  borderColor: Colors.black38,
                ),
          ]),
        ];
      case 'ink':
        final seen = <(int, int), LatLng>{};
        return [
          PolylineLayer(polylines: [
            for (final run in dedupeSegments(
              splitTrackSegments(selected.points),
              seen: seen,
              cellSizeMeters: _fogCellSize,
            ))
              for (final pass in inkStrokes(
                decimate(run, _fogLineDecimation()),
                passCount: inkPassWidthFactors.length,
                minRunLength: inkBaseRunLength,
                maxStripsPerTrack: inkMaxStripsPerTrack,
              ))
                for (final s in pass.strips)
                  Polyline(
                    points: s.run,
                    // Meter-sized: flutter_map converts to pixels at paint
                    // time, so no rebuild is needed when the zoom changes.
                    strokeWidth: inkWidthMeters * pass.width,
                    useStrokeWidthInMeter: true,
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

  /// The photo pins: one disc per cataloged photo, in the surface color
  /// with the primary border (the recording marker's look, smaller),
  /// above the fog and corridors so they read as annotations of visited
  /// places. Each pin's tap opens its preview dialog. Photo markers stay
  /// during recordings and replays — they are catalog state, not session
  /// state.
  List<Widget> _photoMarkerLayers() {
    // The pins hide with the photos setting; the stored photos stay in
    // the catalog and come back when it is re-enabled.
    if (!widget.model.photosEnabled) return const [];
    final photos = widget.model.photos;
    if (photos.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    return [
      MarkerLayer(
        markers: [
          for (final p in photos)
            Marker(
              key: ValueKey('photo-marker-${p.id}'),
              point: LatLng(p.lat, p.lon),
              width: 36,
              height: 36,
              // Not individually tappable (the map's gesture layer sits
              // above marker children) — the map tap routes here via
              // _onMapTap's nearest-photo check.
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.surface,
                    border: Border.all(color: scheme.primary, width: 2),
                    boxShadow: const [
                      BoxShadow(blurRadius: 4, color: Colors.black38),
                    ],
                  ),
                  child: Icon(
                    Icons.photo_camera_outlined,
                    size: 22,
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  /// Opens the photo's preview dialog (image, capture time, reposition,
  /// gallery export, share, delete). A 'reposition' result arms the
  /// tap-to-move mode: the next map tap lands the photo there.
  Future<void> _showPhotoPreview(StoredPhoto photo) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => PhotoPreviewDialog(
        model: widget.model,
        photo: photo,
      ),
    );
    if (action == PhotoPreviewDialog.repositionResult && mounted) {
      setState(() => _repositioningPhoto = photo);
    }
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

  /// The long-press re-arms whichever follow-camera is active (the
  /// recording's or the replay's) and re-centers on its point — the
  /// deliberate, one-gesture way back after a pan released the follow.
  /// In the photo reposition mode the map's taps belong to placing the
  /// pin: a re-centering camera would fight the very next tap, so the
  /// press does nothing there.
  void _onMapLongPress() {
    if (_repositioningPhoto != null) return;
    _rearmActiveFollow();
  }

  /// The armed state as of the previous follow flip — the edge detector
  /// for the release toast below. Null before the first flip: nothing
  /// is known, nothing is compared.
  bool? _followArmedAtLastFlip;

  /// The page's shared follow-flip hook (both dashboards' onFollowChanged
  /// callbacks): rebuilds the page — the drag lock and the pill's locate
  /// slot read the armed state — and, on the arm→release edge while a
  /// session runs, toasts the way back. The session-end reset
  /// (armed→false from the dashboard's boundary detection) is naturally
  /// silent: `isRecording` is already false when that flip lands.
  void _onFollowFlip() {
    final armed = _followArmed;
    if (_followArmedAtLastFlip == true &&
        !armed &&
        widget.model.isRecording) {
      showMapToast(
        context,
        AppStrings.ofContext(context).followReleasedHint,
      );
    }
    _followArmedAtLastFlip = armed;
    setState(() {});
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
    _latestFix = pos;
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
      _latestFix = pos;
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

  /// The position a photo taken right now would be tagged with: the
  /// session's live fix while recording (fresher than any cached fix),
  /// else the latest fix this run obtained. Null when there is none — the
  /// camera button is hidden then (nothing to tag a photo with).
  ///
  /// Deliberately not [_locatedPosition]: that one drops when the user
  /// pans away (the marker's rule), while a photo still belongs where the
  /// user is. The capture does not request a fresh fix either — a photo
  /// press must not wait on a cold GPS; the position is editable from the
  /// preview afterward.
  LatLng? get _photoPosition {
    if (widget.model.isRecording) {
      final session = widget.model.recording;
      final lat = session?.currentLat;
      final lon = session?.currentLon;
      if (lat != null && lon != null) return LatLng(lat, lon);
    }
    return _latestFix;
  }

  /// Camera action: capture through the model, then say what happened —
  /// the camera app returns to the map after the shot, so without a toast
  /// a decline and a save would look identical.
  Future<void> _takePhoto() async {
    final strings = AppStrings.ofContext(context);
    final position = _photoPosition;
    if (position == null) return; // no fix: the button is not shown
    final result = await widget.model.takePhoto(position);
    if (!mounted) return;
    switch (result) {
      case PhotoAdded():
        _toast(strings.photoAdded);
      case PhotoAddDeclined():
        _toast(strings.photoDeclined);
      case PhotoAddFailed():
        _toast(strings.photoFailed);
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
    // One claim grid across every aggregate, in model order: a cell an
    // earlier aggregate already unlocked is not unlocked again, so with
    // many overlapping tracks the layer's cost stays the union's, not
    // the sum over tracks.
    final seen = <(int, int), LatLng>{};
    for (final a in widget.model.aggregates) {
      final centers = claimUnlockCenters(
        a.points,
        seen: seen,
        cellSizeMeters: _fogCellSize,
      );
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

  /// The fog overlay as one memoized [CircleLayer]: the shared claim
  /// grid makes a cell's circle depend on every earlier aggregate, so
  /// the built layer — not per-aggregate centers — is what gets cached,
  /// under [_fogOverlayKey] (the `_fogLineLayer` pattern).
  CircleLayer? _fogCircleLayerCache;
  String? _fogCircleLayerKey;

  CircleLayer _fogCircleLayer(List<MapTrack> tracks) {
    final key = _fogOverlayKey();
    final cached = _fogCircleLayerCache;
    if (cached != null && key == _fogCircleLayerKey) return cached;
    _fogCircleLayerKey = key;
    return _fogCircleLayerCache =
        CircleLayer(circles: _buildFogCircles(tracks));
  }

  /// Everything the built fog layers depend on besides the style: the
  /// fog band plus every aggregate's membership and tint. One key for
  /// the circle and line layers alike.
  String _fogOverlayKey() {
    final model = widget.model;
    final tintKeys = model.aggregateTintKeys;
    return [
      _fogCellSize,
      for (final a in model.aggregates)
        '${a.anchorId}{${[for (final t in a.members) t.id].join('|')}}${tintKeys[a.anchorId]}',
    ].join(';');
  }

  /// The fog overlay in the two line styles: per aggregate, its
  /// deduped track segments as uniform polylines in the aggregate tint —
  /// raised alpha, since a thin line needs more opacity than the
  /// circles to read. The ink style draws the same deduped geometry as
  /// layered meter-sized ink passes (bleed under core). One claim grid
  /// is shared across the aggregates in model order (see
  /// [_buildFogCircles]): ground an earlier track already covers is
  /// never drawn again, with one-point handoffs keeping the lines
  /// continuous where a run resumes at covered ground's edge.
  List<Polyline> _buildFogLines(List<MapTrack> tracks) {
    final model = widget.model;
    final tintKeys = model.aggregateTintKeys;
    final ink = model.fogStyle == 'ink';
    final out = <Polyline>[];
    final seen = <(int, int), LatLng>{};
    for (final a in model.aggregates) {
      final tint = exploredAreaColor(tintKeys[a.anchorId] ?? defaultTintKey);
      final runs = dedupeSegments(
        splitTrackSegments(a.points),
        seen: seen,
        cellSizeMeters: _fogCellSize,
      );
      for (final run in runs) {
        final pts = decimate(run, _fogLineDecimation());
        if (pts.length < 2) continue;
        if (!ink) {
          out.add(Polyline(points: pts, strokeWidth: 3.5, color: tint));
        } else {
          for (final pass in inkStrokes(
            pts,
            passCount: inkPassWidthFactors.length,
            minRunLength: inkBaseRunLength,
            maxStripsPerTrack: inkMaxStripsPerTrack,
          )) {
            for (final s in pass.strips) {
              out.add(Polyline(
                points: s.run,
                // Meter-sized like the fog circles: flutter_map converts to
                // pixels at paint time, so zoom changes need no rebuild.
                strokeWidth: inkWidthMeters * pass.width,
                useStrokeWidthInMeter: true,
                color: inkColorFor(tintKeys[a.anchorId] ?? defaultTintKey)
                    .withValues(alpha: pass.alpha),
              ));
            }
          }
        }
      }
    }
    return out;
  }

  /// The fog overlay as one memoized [PolylineLayer] for the two line
  /// styles, under the shared [_fogOverlayKey] (prepended with the
  /// style): the key covers everything the built polylines depend on —
  /// style, fog band, aggregate membership, tints, and through those
  /// the cross-aggregate claims — so on unrelated page rebuilds the
  /// identical widget instance is returned and Flutter skips the
  /// layer's didUpdateWidget: flutter_map then keeps its projection
  /// and simplification caches instead of re-projecting every strip on
  /// every model notification (the gesture-settle one included).
  PolylineLayer? _fogLineLayerCache;
  String? _fogLineLayerKey;

  PolylineLayer _fogLineLayer(List<MapTrack> tracks) {
    final key = '${widget.model.fogStyle};${_fogOverlayKey()}';
    final cached = _fogLineLayerCache;
    if (cached != null && key == _fogLineLayerKey) return cached;
    _fogLineLayerKey = key;
    return _fogLineLayerCache =
        PolylineLayer(polylines: _buildFogLines(tracks));
  }

  /// The camera zoom at the last map event, or null before the first
  /// one; drives the member-picking lanes' meter-to-pixel lane spacing.
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
              // While a followed thing (a session or a replay) rides
              // with the follow-camera armed, one-finger drags are
              // peeks: the drag bit stays on (the hand pans live —
              // never a dead map), but the fling bit goes off —
              // momentum would fight the lift's return glide, and a
              // fling bit left on ends every one-finger gesture with a
              // phantom dragEnd-sourced event that reads as the hand.
              // The follow-camera itself holds the peek: targets
              // arriving mid-drag are stored, never eased toward, and
              // the lift glides back to the latest fix/cursor framing.
              interactionOptions: InteractionOptions(
                flags: (widget.model.isRecording ||
                            widget.model.playback != null) &&
                        _followArmed
                    ? InteractiveFlag.all & ~InteractiveFlag.flingAnimation
                    : InteractiveFlag.all,
                keyboardOptions: const KeyboardOptions(
                  enableArrowKeysPanning: true,
                  enableRFZooming: true, // Enable R/F keys for zoom
                  autofocus: true,
                ),
              ),
              // Tap within tolerance of an aggregate's points selects it
              // (the selection bar appears below); a tap on empty map
              // deselects, which is the bar's way away too.
              onTap: (tapDetail, tap) => _onMapTap(tap),
              // Long-press is the way back to an armed follow after a
              // deliberate pan away — a gesture that cannot move the
              // camera, so it can never be the accidental one.
              onLongPress: (tapDetail, latLng) => _onMapLongPress(),
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
                  'polyline' || 'ink' => _fogLineLayer(mapTracks),
                  _ => _fogCircleLayer(mapTracks),
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
              // The photo pins, above the fog and corridors.
              ..._photoMarkerLayers(),
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
          // the band inset-aware; both edges start below the toolbar band,
          // so the centered toolbar never overlaps either bar on narrow
          // screens — and both bars share the same band, so the pill and
          // its mirror (the record cluster below) stay specular.
          Positioned(
            top: 0,
            bottom: 0,
            left: widget.model.zoomSliderSide == 'left' ? 12 : null,
            right: widget.model.zoomSliderSide == 'left' ? null : 12,
            child: SafeArea(
              minimum: const EdgeInsets.only(
                top: kToolbarHeight + 24,
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
          // vertically centered in the same band as the pill — an exact
          // mirror of it, not anchored differently. Big labeled buttons
          // away from the other controls, sized for a handlebar mount.
          // Only where the platform has a location plugin: a record button
          // on a GPS-less platform would be a dead button (its slot also
          // stays hidden until a real fix arrived, see `RecordCluster`).
          if (widget.locationSupported && widget.model.playback == null)
            Positioned(
              top: 0,
              bottom: 0,
              left: widget.model.zoomSliderSide == 'left' ? null : 12,
              right: widget.model.zoomSliderSide == 'left' ? 12 : null,
              child: SafeArea(
                minimum: const EdgeInsets.only(
                  top: kToolbarHeight + 24,
                  bottom: 16,
                ),
                child: Center(
                  child: RecordCluster(
                    model: widget.model,
                    gpsWorking: _gpsWorking,
                    // The camera press is offered only with a position to
                    // tag the photo with and the photos feature on; on a
                    // replay-less map without a fix there is nothing to
                    // tag, so the button stays off rather than failing.
                    onTakePhoto: (_photoPosition != null &&
                            widget.model.photosEnabled)
                        ? _takePhoto
                        : null,
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
                  // Reposition mode's banner: below the toolbar, one row —
                  // the instruction and a Cancel that leaves the photo
                  // where it was.
                  if (_repositioningPhoto != null) ...[
                    const SizedBox(height: 8),
                    Card(
                      key: const ValueKey('reposition-banner'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                strings.photoRepositionHint,
                                maxLines: 2,
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('reposition-cancel'),
                              onPressed: () =>
                                  setState(() => _repositioningPhoto = null),
                              child: Text(strings.cancel),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
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
                    onFollowChanged: _onFollowFlip,
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
                    onFollowChanged: _onFollowFlip,
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

  /// Desktop hover in picking mode: glow a *revealed* lane under the
  /// cursor — plain lines do not glow (their overlaps are not spread,
  /// so a hover there would glow an ambiguous spot).
  void _onPickingHover(PointerHoverEvent event) {
    if (!widget.model.memberPicking) return;
    final candidates = _laneCandidatesAt(event.localPosition, tolerancePx: 12);
    final hit = candidates.isEmpty ? null : candidates.first.$1;
    final id = hit != null && _revealIds.contains(hit) ? hit : null;
    if (id != _hoveredMemberId) setState(() => _hoveredMemberId = id);
  }
}
