import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../l10n/app_strings.dart';
import '../playback/track_playback.dart';
import 'app_model.dart';
import 'follow_camera.dart';
import 'format.dart';
import 'recording_dashboard.dart'
    show rotationModeIcon, rotationModeName;

/// The playback dashboard: the replay bar (play/pause/replay, track
/// name, elapsed/total, the speed chip, the rotation mode and close)
/// and the follow-camera wiring that rides the replay — [FollowCamera]
/// itself is shared with the recording dashboard (see `follow_camera.dart`),
/// so a replay moves the camera *exactly* like a session does: same
/// glide easing, same framing lead, same release-on-gesture, same
/// north-up/course-up modes from the shared `mapRotation` setting.
///
/// The heading policy is this side's to compute (the recording's is the
/// device's): a timeline's course is the engine's interpolated bearing,
/// always known, never stale — no compass, no hysteresis gates.
///
/// Like the recording dashboard, this is not the tick's owner: `MapPage`
/// owns the replay timer (a model must never hold a timer no page
/// listens to) and this dashboard reacts, feeding the follow-camera
/// from the per-tick channel ([AppModel.player]'s `playbackLive`).
class PlaybackDashboard extends StatefulWidget {
  const PlaybackDashboard({
    super.key,
    required this.model,
    required this.mapController,
    required this.bottomOverlap,
  });

  final AppModel model;
  final MapController mapController;

  /// Pixels the page's bottom overlay column occupies from the screen
  /// bottom right now (see `MapPage.bottomOverlap`): the follow-camera
  /// keeps the marker above it, so it never hides under this bar.
  final double Function() bottomOverlap;

  @override
  State<PlaybackDashboard> createState() => _PlaybackDashboardState();
}

class _PlaybackDashboardState extends State<PlaybackDashboard>
    with TickerProviderStateMixin {
  /// The shared follow-camera, fed per tick with the engine's
  /// interpolated position and course.
  late final FollowCamera _follow;

  /// The engine this dashboard last served — the replay boundary
  /// detector: a new [TrackPlayback] instance is a new replay, which
  /// re-arms the follow exactly like a session boundary does.
  TrackPlayback? _served;

  @override
  void initState() {
    super.initState();
    _follow = FollowCamera(
      mapController: widget.mapController,
      bottomOverlap: widget.bottomOverlap,
      screenHeight: () {
        final view = View.of(context);
        return view.physicalSize.height / view.devicePixelRatio;
      },
      tickerFactory: createTicker,
    );
    widget.model.addListener(_onModelChanged);
    widget.model.player.playbackLive.addListener(_onPlaybackTick);
    _onModelChanged();
  }

  @override
  void dispose() {
    _follow.dispose();
    widget.model.removeListener(_onModelChanged);
    widget.model.player.playbackLive.removeListener(_onPlaybackTick);
    super.dispose();
  }

  /// The replay's boundaries arm and disarm the follow-camera: starting
  /// a replay rides it, stopping or replacing one resets it (see
  /// [FollowCamera.reset] — the session dashboard's boundary pair).
  void _onModelChanged() {
    if (!mounted) return;
    final playback = widget.model.playback;
    if (!identical(playback, _served)) {
      _served = playback;
      _follow.reset(armed: playback != null);
    }
  }

  /// One replay tick: the marker, bar and trace read the engine; the
  /// camera rides the interpolated position, rotating to the course in
  /// the 'course' mode (a null heading glides the position and holds the
  /// rotation — the 'north' mode's behavior, and the map stayed
  /// wherever the user left it when the course is unknown).
  void _onPlaybackTick() {
    if (!mounted) return;
    final playback = widget.model.playback;
    if (playback == null || !_follow.follow) return;
    final heading = widget.model.mapRotation == 'course' ? playback.course : null;
    _follow.update(playback.position, heading);
  }

  /// Arms the follow and feeds the engine's current state once — the
  /// play button's way back after a gesture release (and the first feed
  /// of a resumed replay: the timer's next tick follows right behind).
  void _armAndFeed() {
    _follow.arm();
    _onPlaybackTick();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.model.playback == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: widget.model.player.playbackLive,
      builder: (context, _) => _bar(widget.model.playback!),
    );
  }

  /// The replay bar: one compact Card row. The values (times, speed) are
  /// plain formats; the tooltips are the only localizable text.
  Widget _bar(TrackPlayback playback) {
    final strings = AppStrings.ofContext(context);
    final playing = playback.status == PlaybackStatus.playing;
    final icon = playing
        ? Icons.pause
        : (playback.finished ? Icons.replay : Icons.play_arrow);
    final tooltip = playing
        ? strings.pauseLabel
        : (playback.finished ? strings.playbackReplay : strings.playbackPlay);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        key: const ValueKey('playback-bar'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: const ValueKey('playback-play'),
                tooltip: tooltip,
                icon: Icon(icon),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  if (playing) {
                    widget.model.player.pause();
                  } else {
                    widget.model.player.play();
                    // The play (re)arms the follow-camera — the
                    // replay button's behavior after the finish.
                    _armAndFeed();
                  }
                },
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  playback.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${formatDuration(playback.elapsed)} / '
                '${formatDuration(playback.total)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(width: 4),
              TextButton(
                key: const ValueKey('playback-speed'),
                onPressed: () => widget.model.player.cycleSpeed(),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text('${playback.speed.toStringAsFixed(0)}×'),
              ),
              // The rotation-mode button, the recording chip's twin:
              // cycles the shared setting, the follow-camera reads it.
              IconButton(
                key: const ValueKey('playback-rotation-mode'),
                tooltip: rotationModeName(strings, widget.model.mapRotation),
                icon: Icon(rotationModeIcon(widget.model.mapRotation)),
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  final modes = AppModel.rotationModes;
                  final next = modes[(modes.indexOf(widget.model.mapRotation) +
                          1) %
                      modes.length];
                  widget.model.setMapRotation(next);
                },
              ),
              IconButton(
                key: const ValueKey('playback-close'),
                tooltip: strings.playbackClose,
                icon: const Icon(Icons.close),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                onPressed: () => widget.model.stopPlayback(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
