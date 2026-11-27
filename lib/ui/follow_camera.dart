import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show Ticker, TickerCallback;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../debug_log.dart';

/// The angle equivalent to [course] (mod 360) closest to [reference] —
/// the camera rotation the course is applied against — so a course
/// crossing the 0/360 boundary rotates through the short arc, never the
/// long way around.
double nearestEquivalentRotation(double course, double reference) =>
    course + 360 * ((reference - course) / 360).roundToDouble();

/// The follow-camera, shared by everything that rides a moving point on
/// the map (the recording session, track playback): it eases the camera
/// toward each supplied target — position, and a heading for the course-up
/// rotation mode — with the framing that keeps the point above the bottom
/// overlay column, and releases when the user's hand moves the map.
///
/// The host owns the *cadence* and the *heading policy*: a session feeds
/// its ~1 Hz fixes (its reported heading, with the compass fallback and
/// the stale-fix hold computed there — a `null` heading glides the
/// position but holds the rotation), playback feeds its interpolated
/// track course per tick. Everything else — the glide easing, the
/// framing, the release-on-gesture, the rotation math — lives here once,
/// so both hosts move the camera identically by construction.
///
/// One escape from the release-on-gesture: with [dragPeeks] on (the
/// recording's policy), a one-finger drag is a *peek* — the hand pans
/// the map live (never a dead map), the follow stays armed, targets
/// arriving mid-peek are held, and on lift the camera glides back to
/// the latest fix framing. A gesture with more intent (two fingers,
/// double-tap, wheel) still releases.
///
/// This is deliberately not a widget: it needs the host's `createTicker`
/// (a `TickerProvider` mixin belongs to a state) and glides the camera
/// through the [MapController] it is handed, so a per-fix or per-tick
/// repaint never has to go through a setState of any tree.
class FollowCamera {
  FollowCamera({
    required this.mapController,
    required this.bottomOverlap,
    required this.screenHeight,
    required Ticker Function(TickerCallback) tickerFactory,
    this.onFollowChanged,
    this.onFirstPeek,
  }) : _createTicker = tickerFactory {
    // The follow-camera releases on a gesture that moves the map — drags,
    // multi-finger gestures, the fling/double-tap-zoom animations that
    // report through their own sources after the gesture ends, and the
    // desktop scroll wheel (a zoom hand, not a pan, but it moves the
    // camera just the same). Plain taps don't release it. Only a re-arm
    // ([arm]/[rearm]) or a fresh session or playback arms it again —
    // except the one-finger peek below, which never releases at all.
    _mapEvents = mapController.mapEventStream.listen((event) {
      // A gesture that changed the zoom adopts it as the ride's zoom —
      // even on the very event that releases the follow (the releasing
      // event is the first the hand emits, and its camera is the zoom the
      // hand actually left, not an intermediate one), and even while the
      // follow is already off: after the release the listener below would
      // return early and the gesture's final zoom would never be seen.
      // A pure pan changes no zoom and adopts nothing. A glide frame is
      // never a gesture source, so no [_isGlideWrite] guard is needed here.
      if (event is MapEventWithMove &&
          _moveGestures.contains(event.source) &&
          event.oldCamera.zoom != event.camera.zoom) {
        _adoptRideZoom(event.camera.zoom);
      }
      if (!follow) return;
      if (_moveGestures.contains(event.source)) {
        // The peek policy: a one-finger drag while [dragPeeks] is on
        // takes the camera without disengaging the follow — the hand
        // pans live, and on lift ([_endPeek]) the camera glides back to
        // the latest held target. Any other move gesture (or a second
        // finger joining the drag, which re-sources the gesture as
        // multi-finger) cancels the peek and releases as always.
        if (dragPeeks) {
          if (event.source == MapEventSource.dragStart) {
            _startPeek();
            return;
          }
          if (event.source == MapEventSource.onDrag && _peeking) return;
          if (event.source == MapEventSource.dragEnd && _peeking) {
            _endPeek();
            return;
          }
        }
        _peeking = false;
        release(event.source);
        return;
      }
      // A zoom-only move issued through the host controller is the
      // lateral zoom slider's hand (it passes the camera's center
      // through unchanged): the ride adopts that zoom as its own
      // instead of re-flooring to [followZoomFloor] on the next tick.
      // The glide's own frames move the center while converging, so a
      // center-static frame can only come from outside the glide — and
      // an exact match against the camera the glide last wrote (see
      // [_lastGlideCamera]) rules out the settled and barely-converged
      // frames whose zoom is already the glide's own target.
      if (event is MapEventWithMove &&
          event.source == MapEventSource.mapController &&
          event.oldCamera.center == event.camera.center &&
          event.oldCamera.zoom != event.camera.zoom &&
          !_isGlideWrite(event.camera)) {
        _adoptRideZoom(event.camera.zoom);
      }
    });
  }

  /// Adopts [zoom] as the ride's zoom (the user's hand set it): the next
  /// target rides it instead of re-flooring to [followZoomFloor], and a
  /// glide still in flight is re-targeted onto it *now* — the hand wins
  /// in the same frame, not on the next fix. Otherwise the running ticker
  /// keeps easing back toward its stale zoom target: the tap is undone
  /// for up to a fix interval (~1 s), then springs the other way once the
  /// next fix adopts it, which reads as the zoom bouncing under the
  /// user's taps. The center and rotation targets stay: only the zoom the
  /// hand changed is re-targeted (it equals the camera's zoom now, so the
  /// glide stops changing it and keeps easing the framing).
  void _adoptRideZoom(double zoom) {
    _rideZoom = zoom;
    final target = _glideTarget;
    if (target != null) {
      _glideTarget = (center: target.center, zoom: zoom, rotation: target.rotation);
    }
  }

  /// The camera this FollowCamera moves. The host hands over the same
  /// controller its map renders with.
  final MapController mapController;

  /// Pixels the host's bottom overlay column occupies from the screen
  /// bottom right now (see `MapPage.bottomOverlap`): the follow-camera
  /// keeps the point above it, so the marker never hides under a HUD.
  final double Function() bottomOverlap;

  /// The physical view's height in logical pixels (see
  /// `RecordingDashboard`): the framing lead below is measured against it.
  final double Function() screenHeight;

  /// Optional host hook, fired whenever [follow] flips (a gesture
  /// releases, [arm] re-arms); the recording dashboard rebuilds on it.
  final void Function()? onFollowChanged;

  /// Optional host hook, fired once per followed thing on the first
  /// peek's return ([_endPeek]) — the dashboards teach the two-finger
  /// escape with it. The latch resets with the followed thing
  /// ([reset]), so a session or replay teaches once, never nagging.
  final void Function()? onFirstPeek;

  /// The host state's `createTicker`, bound at construction.
  final Ticker Function(TickerCallback) _createTicker;

  /// The follow-camera: armed by the host (a session start, a playback
  /// start, a locate shortcut), and a user pan or two-finger rotation
  /// releases it — a target must never pull the view back against the
  /// user's hand.
  bool _follow = false;
  bool get follow => _follow;

  /// Whether the followed thing's peek policy is on: a one-finger drag
  /// while [follow] is armed pans the map live and glides back on lift,
  /// instead of releasing the follow. Set by both dashboards at their
  /// followed-thing boundaries ([reset] sites — the recording and the
  /// replay alike, so the two hosts peek identically by construction);
  /// it only ever matters while the follow is armed — released or idle
  /// cameras never see a peek.
  bool dragPeeks = false;

  /// True while the peeking hand owns the camera (a one-finger drag
  /// started, the finger not yet lifted): targets arriving per fix are
  /// stored but never eased toward — nothing pulls against the hand —
  /// and the dragEnd ends the peek and glides back. Any other move
  /// gesture cancels it and releases.
  bool _peeking = false;

  /// The last point fed to [update], whatever the follow's state: the
  /// peek's home target, so a peek shorter than a fix interval still
  /// returns to the framing the follow was holding when the drag began.
  LatLng? _lastPoint;

  /// Whether [onFirstPeek] has fired for this followed thing: the
  /// teaching toast shows once per session/replay, never per peek —
  /// accidental brushes must not nag. Cleared with the followed thing
  /// ([reset]).
  bool _taughtPeek = false;

  /// The follow-camera glide: each target (see [update]) stores itself
  /// here and the ticker below eases the camera toward it frame by frame
  /// (flutter_map's move is instant, so discrete targets — 1 Hz fixes,
  /// playback ticks — would otherwise stutter the view). Null when
  /// nothing is gliding.
  ({LatLng center, double zoom, double rotation})? _glideTarget;

  /// The glide ticker, alive only while a target is pending or in flight.
  Ticker? _glideTicker;

  /// The camera the glide last wrote, as flutter_map stored it (the
  /// controller clamps zoom, so this is read back from the camera, never
  /// the requested value): the map-event listener uses it to tell the
  /// glide's own frames apart from the user's hand, which must adopt the
  /// zoom. Kept across [stopGlide] — a glide frame's event can still be
  /// delivered after the glide stopped, and adopting it would pin the
  /// ride to a mid-glide zoom. Cleared on a followed-thing boundary
  /// ([reset]), where no earlier glide frame can still be in flight.
  ({LatLng center, double zoom})? _lastGlideCamera;

  /// Whether [camera] is exactly the one the glide last wrote — its own
  /// frame, never the user's hand.
  bool _isGlideWrite(MapCamera camera) {
    final last = _lastGlideCamera;
    return last != null &&
        last.center == camera.center &&
        last.zoom == camera.zoom;
  }

  /// Elapsed time at the previous glide frame, for the per-frame delta.
  Duration _prevGlideElapsed = Duration.zero;

  /// The last [headingSmoothingWindow] headings seen by [update], averaged
  /// circularly into the rotation target, so per-fix heading noise glides
  /// instead of stepping the camera target by target.
  final List<double> _recentHeadings = [];

  StreamSubscription<MapEvent>? _mapEvents;

  /// Hysteresis for the course-up camera rotation: a target only sets a
  /// new rotation target when the course delta vs the current rotation
  /// reaches this many degrees; below, the target keeps the current
  /// rotation.
  static const double courseDeltaThreshold = 1.0;

  /// Time constant of the follow-camera glide (exponential approach,
  /// critical-damped per frame): tau ~ 350 ms, so the camera converges
  /// over roughly a second after each target instead of snapping.
  static const Duration followGlideTau = Duration(milliseconds: 350);

  /// One glide frame may advance at most this much time of the ease: a
  /// dropped frame or clock hiccup must not hand the exponential a
  /// multiple-of-tau step (a visible snap). At 100 ms over tau = 350 ms
  /// no single frame advances more than ~25% of the remaining distance.
  static const int glideMaxFrameMs = 100;

  /// Settle epsilons below which the glide stops and the ticker idles:
  /// the camera must not repaint at a standstill.
  static const double _glideZoomEpsilon = 0.001;
  static const double _glideLatEpsilon = 1e-7;
  static const double _glideLonEpsilon = 1e-7;
  static const double _glideRotationEpsilon = 0.05;

  /// Number of recent usable headings averaged (circular mean) into the
  /// rotation target, so heading noise glides instead of stepping the
  /// camera target by target. Five entries is about five seconds at the
  /// session's 1 Hz.
  static const int headingSmoothingWindow = 5;

  /// Minimum zoom while the follow-camera rides a target, so the
  /// following view never gets too zoomed out.
  static const double followZoomFloor = 17.0;

  /// The follow-camera offsets at most this fraction of the screen height
  /// opposite screen-up from the point, so the position marker sits
  /// horizontally centered but slightly below the vertical center — more
  /// of what is ahead stays in view. The lead shrinks when the bottom
  /// overlay column needs the room (see [bottomOverlap] and
  /// [followLeadMargin]) so the marker never hides under the HUD; on a
  /// short screen with a panel open it reaches zero and the point sits at
  /// the center.
  static const double followLeadFraction = 0.18;

  /// Breathing room between the marker and the top of the bottom overlay
  /// column.
  static const double followLeadMargin = 16;

  /// Map-event sources that count as the user's hand moving the map: a
  /// drag, a multi-finger gesture, or the fling/double-tap-zoom animations
  /// that continue a gesture after its end. Plain taps and long-presses
  /// don't move the camera, so they must not release the follow — a
  /// stray tap would silently disengage the centering mid-ride.
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
    MapEventSource.scrollWheel,
  };

  /// Arms the follow without moving the camera: used when the camera is
  /// already where the next target will land — the next target takes
  /// over from there.
  void arm() {
    if (!_follow) {
      DebugLog.instance.info('follow armed');
      _follow = true;
      onFollowChanged?.call();
    }
  }

  /// The way back to the follow after a pan away: arms the follow and
  /// re-centers on [pos] at the user's zoom (a plain move — the glide
  /// starts with the next target), so the camera and the course-up
  /// rotation come back with it.
  void rearm(LatLng pos) {
    arm();
    mapController.move(pos, mapController.camera.zoom);
  }

  /// The followed thing's boundary (a session or playback starts or
  /// ends): forces the follow state — [armed] arms it, otherwise it
  /// drops — stops any in-flight glide, forgets the smoothed headings
  /// and any peek in flight, so stale state never leaks across the
  /// boundary. Unlike [release] this is not a gesture: nothing is
  /// logged as one.
  void reset({required bool armed}) {
    stopGlide();
    _peeking = false; // a boundary never leaks a peek in flight
    _taughtPeek = false; // a new followed thing teaches its peek once
    clearHeadingWindow();
    _lastGlideCamera = null; // no earlier glide frame can still be in flight
    _rideZoom = null; // a new followed thing starts under the floor policy
    if (_follow == armed) return;
    _follow = armed;
    onFollowChanged?.call();
  }

  /// The zoom the user's hand set while the ride is armed — the pill's +/−
/// buttons (a center-static programmatic move) or a gesture that changed
/// the zoom (pinch, scroll wheel, double-tap/fling) — null until then:
/// the follow targets this instead of [followZoomFloor], so a zoom-out
/// below the floor is held, not walked back. Cleared on a followed-thing
/// boundary ([reset]); kept across a plain release/re-arm, so the hand's
/// zoom survives a pan away and back (e.g. a pinch zoom-out followed by a
/// Locate re-arm).
  double? _rideZoom;

  /// Forgets the smoothed headings — call when the followed thing
  /// changes (a session boundary, a playback start): stale headings must
  /// not seed the next rotation target.
  void clearHeadingWindow() => _recentHeadings.clear();

  /// Releases the follow on a user gesture that moved the map; only an
  /// [arm]/[rearm] (or a fresh followed thing) arms it again. The
  /// releasing event's source goes to the debug log so a later export
  /// shows whether a drag or a stray tap disengaged the follow.
  void release(MapEventSource source) {
    DebugLog.instance.info('follow released by gesture (source=${source.name})');
    // The pan owns the camera now: stop any in-flight glide, or the next
    // frame would pull the view back against the user's hand.
    stopGlide();
    _follow = false;
    onFollowChanged?.call();
  }

  /// Feeds one target into the camera: the point to ride ([heading] is
  /// the course to rotate to in course-up mode, or null to glide the
  /// position and hold the current rotation — a stale or compass-less
  /// target). The zoom is the ride's own ([_rideZoom] once the user's
  /// slider set one), else the camera's own never below
  /// [followZoomFloor]; the center is the framed one (see
  /// [_framedCenter]). Call this per fix (the session) or per tick
  /// (playback) — the glide smooths whatever cadence arrives.
  void update(LatLng point, double? heading) {
    // The peek's home: remembered on every fix so a drag that starts
    // between fixes still has somewhere to return.
    _lastPoint = point;
    // The ride's zoom: the user's slider zoom once one was set, else
    // never below the floor.
    final zoom = _rideZoom ?? math.max(mapController.camera.zoom, followZoomFloor);
    final center = _framedCenter(point, zoom);
    double targetRotation = mapController.camera.rotation;
    if (heading != null) {
      // The rotation target is the circular mean of the last few usable
      // headings (atan2 of summed sin/cos — wrap-safe across 0/360), so
      // heading noise averages out instead of stepping the camera.
      _recentHeadings.add(heading);
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
      // (the map content is wrapped in Transform.rotate(rotationRad)), so
      // a geographic bearing shows up at screen bearing bearing +
      // rotation. Course-up therefore needs rotation = -heading, not
      // +heading.
      final target = -meanHeading;
      final rotation = mapController.camera.rotation;
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

  /// Stores the next camera target and starts the glide ticker if it is
  /// not running — unless the peeking hand owns the camera: then the
  /// freshest target is only stored (nothing may pull against the
  /// hand), and the lift ([_endPeek]) starts the glide.
  void _setGlideTarget(LatLng center, double zoom, double rotation) {
    _glideTarget = (center: center, zoom: zoom, rotation: rotation);
    if (_peeking) return;
    // A fresh ticker starts its clock at zero — its first tick measures a
    // one-frame dt. A ticker that is *still running* keeps its monotonic
    // elapsed: resetting the clock here would make its next tick read the
    // ticker's whole age as one frame's dt, and the exponential ease would
    // jump most of the remaining distance in a single frame — the visible
    // snap a target arrives mid-glide.
    if (_glideTicker == null) {
      _prevGlideElapsed = Duration.zero;
      _glideTicker = _createTicker(_glideTick)..start();
    }
  }

  /// The peek begins (a one-finger dragStart while [dragPeeks] is on and
  /// the follow armed): the hand owns the camera now — any in-flight
  /// glide stops, and a home target from the last fix is stored without
  /// a ticker, so a peek with no fix inside still returns to the
  /// framing the follow was holding when the drag began.
  void _startPeek() {
    _peeking = true;
    stopGlide();
    final point = _lastPoint;
    if (point != null) update(point, null);
  }

  /// The finger lifted: the follow was armed all along — glide back to
  /// the freshest held target (the latest fix's framing, rotation
  /// included, the same easing as every follow glide). A session with no
  /// fix yet holds no target: the camera waits where the hand left it
  /// for the first fix to glide it in. The first return per followed
  /// thing teaches: [onFirstPeek] fires once (see [_taughtPeek]).
  void _endPeek() {
    _peeking = false;
    if (_glideTarget != null && _glideTicker == null) {
      _prevGlideElapsed = Duration.zero;
      _glideTicker = _createTicker(_glideTick)..start();
    }
    if (!_taughtPeek) {
      _taughtPeek = true;
      onFirstPeek?.call();
    }
  }

  /// One glide frame: exponential approach (critical damped, tau =
  /// [followGlideTau]) of center, zoom and rotation toward the target,
  /// rotation through the short arc. One `moveAndRotate` per frame.
  /// Stops the ticker once settled — no repaint at a standstill.
  void _glideTick(Duration elapsed) {
    final target = _glideTarget;
    if (target == null) {
      stopGlide();
      return;
    }
    // Cap dt before the ease: a dropped-frame pause (or any clock hiccup)
    // must not hand the exponential one multiple-of-tau step, or the ease
    // lands a visible snap.
    final rawDtMs = (elapsed - _prevGlideElapsed).inMilliseconds;
    final dtMs = rawDtMs.clamp(0, glideMaxFrameMs);
    _prevGlideElapsed = elapsed;
    final k =
        dtMs <= 0
            ? 0.0
            : 1 - math.exp(-dtMs / followGlideTau.inMilliseconds.toDouble());
    final camera = mapController.camera;
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
    mapController.moveAndRotate(
      LatLng(newLat, newLon),
      newZoom,
      newRotation,
    );
    _recordGlideWrite();
    // Settle on the *remaining* distance, not the frame's step: stopping
    // on a small step would leave up to step/(1-k) of residual behind.
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
      mapController.moveAndRotate(
        target.center,
        target.zoom,
        target.rotation,
      );
      _recordGlideWrite();
      stopGlide();
    }
  }

  /// Remembers the camera the glide just wrote — the post-move camera, so
  /// the controller's own clamping is what was really set. The event this
  /// move emits is delivered asynchronously; the listener compares against
  /// this to recognize a glide frame rather than the user's hand.
  void _recordGlideWrite() {
    final camera = mapController.camera;
    _lastGlideCamera = (center: camera.center, zoom: camera.zoom);
  }

  /// Stops the glide and forgets the target: the user's hand owns the
  /// camera after a pan, the followed thing owns it after it ends.
  void stopGlide() {
    _glideTicker?.stop();
    _glideTicker?.dispose();
    _glideTicker = null;
    _glideTarget = null;
    _prevGlideElapsed = Duration.zero;
  }

  /// The camera center for a point: shifted opposite screen-up
  /// (geographic bearing 360 - rotation) so the position sits below the
  /// vertical center — bottom-center in both north-up and course-up
  /// modes, with more of what is ahead in view. The lead is capped by the
  /// room the bottom overlay column leaves, so the marker never hides
  /// under the HUD; a short screen with a panel open puts the point at
  /// the center.
  LatLng _framedCenter(LatLng point, double zoom) {
    final height = screenHeight();
    final lat = point.latitude;
    final lon = point.longitude;
    if (height <= 0) return point;
    final lead = math.min(
      height * followLeadFraction,
      math.max(height / 2 - bottomOverlap() - followLeadMargin, 0),
    );
    if (lead <= 0) return point;
    final metersPerPixel =
        156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
    final offsetMeters = metersPerPixel * lead;
    final upRad = (360 - mapController.camera.rotation) * math.pi / 180;
    return LatLng(
      lat + offsetMeters * math.cos(upRad) / 111320,
      lon +
          offsetMeters *
              math.sin(upRad) /
              (111320 * math.cos(lat * math.pi / 180)),
    );
  }

  /// Stops the glide and drops the map-event subscription. The host calls
  /// this from its `dispose`.
  void dispose() {
    stopGlide();
    _mapEvents?.cancel();
  }
}
