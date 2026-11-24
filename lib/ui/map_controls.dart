/// The map's edge chrome, tuned for a phone on a handlebar or case strap:
/// big labeled buttons on the screen edges, nothing mid-map. The
/// [MapControlPill] (rotation mode, zoom in/out, locate) hugs the
/// configured edge ([AppModel.zoomSliderSide]); the [RecordCluster]
/// (record/pause/resume, stop) mirrors to the opposite edge, vertically
/// centered — see `map_page.dart` for the layout.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../l10n/app_strings.dart';
import '../recording/recording_session.dart';
import 'app_model.dart';
import 'map_actions.dart';

/// OSM standard tiles exist between zoom 0 and 19; 3 is a world view that
/// still feels like a map. Both the camera and the pill's buttons stay
/// inside.
const mapMinZoom = 3.0;
const mapMaxZoom = 19.0;

/// The display name of a rotation mode, for the pill button's tooltip and
/// the Settings segments.
String rotationModeName(AppStrings strings, String mode) => switch (mode) {
      'course' => strings.rotationModeCourse,
      _ => strings.rotationModeNorth,
    };

/// The pill button's icon for a rotation mode: a compass rose while the
/// map is locked north-up, the travel arrow (the position marker's glyph)
/// while the camera rides the course. The mode's name rides as the
/// button's caption (see [rotationModeName]).
IconData rotationModeIcon(String mode) => switch (mode) {
      'course' => Icons.navigation,
      _ => Icons.explore,
    };

/// The edge control pill pinned to the map's configured edge: the
/// north/course rotation toggle on top, then the zoom-in and zoom-out
/// step buttons, then the last slot at the bottom: locate where the
/// platform has a location plugin ([showLocate]), or — on a plugin-less
/// platform while a replay runs — a follow button that re-arms the
/// follow-camera on the replay cursor (the way back after a pan). Every
/// camera move (pinch, wheel, keyboard R/F, double-tap) is still possible;
/// the buttons only add steps. The zoom steps read the live camera, so
/// they clamp at [mapMinZoom]/[mapMaxZoom] exactly like the gestures.
class MapControlPill extends StatelessWidget {
  const MapControlPill({
    super.key,
    required this.controller,
    required this.model,
    required this.onRearmFollow,
    this.showLocate = true,
    this.followArmed = false,
    this.locating = false,
    this.onLocate,
  });

  final MapController controller;
  final AppModel model;

  /// Re-arms the active follow-camera (a recording's or a replay's) and
  /// re-centers on its fix/cursor. Required — the page always supplies
  /// it, dispatching to whichever dashboard is following — and called
  /// only when the rotation button switches *to* course: course-up on a
  /// released camera would otherwise just change a setting while the map
  /// stayed where the pan left it.
  final VoidCallback onRearmFollow;

  /// False on platforms without a location plugin (desktop Linux): the
  /// locate action could only ever fail there — but while a replay runs,
  /// the last slot still shows and becomes the follow-replay button.
  final bool showLocate;

  /// True while a follow-camera (a recording's or a replay's) is armed on
  /// the map: the last slot is then redundant — the camera is already
  /// where the button would take it — so it goes away until a pan
  /// releases the follow.
  final bool followArmed;

  /// True while a locate attempt is in flight: the button shows a
  /// spinner and ignores further taps.
  final bool locating;
  final VoidCallback? onLocate;

  void _moveTo(double zoom) {
    final target = zoom.clamp(mapMinZoom, mapMaxZoom);
    final camera = controller.camera;
    if (target == camera.zoom) return;
    controller.move(camera.center, target);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final scheme = Theme.of(context).colorScheme;
    // The last slot: GPS locate where the platform has a location plugin,
    // a follow button while a replay runs on a plugin-less platform. It
    // takes a break while a follow-camera is armed: the camera is then
    // already locked on the thing the button would re-center on.
    final followReplay = model.playback != null;
    final showLastSlot = !followArmed && (showLocate || model.playback != null);
    return Container(
      key: const ValueKey('control-pill'),
      // Horizontal padding keeps the captions clear of the rounded border.
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(blurRadius: 6, color: Colors.black26, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The rotation-mode toggle: one global control for the shared
          // setting — the follow-camera (recording and playback alike)
          // reads it. Labelled like the zoom buttons: the mode's name as
          // the caption ("North up" / "Course up").
          HeaderAction(
            key: const ValueKey('rotation-mode-button'),
            icon: Icon(rotationModeIcon(model.mapRotation)),
            label: rotationModeName(strings, model.mapRotation),
            tooltip: rotationModeName(strings, model.mapRotation),
            width: 56,
            iconSize: 24,
            onTap: () {
              void snapNorth() {
                // A programmatic move: it never releases an armed follow.
                final camera = controller.camera;
                controller.moveAndRotate(camera.center, camera.zoom, 0.0);
              }

              if (model.isRecording || model.playback != null) {
                // A follow-camera exists: toggle north/course, and make
                // the tap do something visible either way — course
                // re-arms a released follow so the camera comes along,
                // north snaps the map north on the spot, since a
                // released follow would never turn it back on its own.
                final modes = AppModel.rotationModes;
                final next =
                    modes[(modes.indexOf(model.mapRotation) + 1) %
                        modes.length];
                model.setMapRotation(next);
                if (next == 'course') {
                  onRearmFollow();
                } else {
                  snapNorth();
                }
              } else {
                // Idle: the tap just sets north — and snaps the camera
                // to rotation 0, so the button visibly orients the map
                // even after a manual two-finger rotate (course-up has
                // no meaning with nothing moving).
                model.setMapRotation('north');
                snapNorth();
              }
            },
          ),
          HeaderAction(
            key: const ValueKey('zoom-in-button'),
            icon: const Icon(Icons.add),
            label: strings.zoomIn,
            tooltip: strings.zoomIn,
            onTap: () => _moveTo(controller.camera.zoom + 1),
            width: 56,
            iconSize: 24,
          ),
          HeaderAction(
            key: const ValueKey('zoom-out-button'),
            icon: const Icon(Icons.remove),
            label: strings.zoomOut,
            tooltip: strings.zoomOut,
            onTap: () => _moveTo(controller.camera.zoom - 1),
            width: 56,
            iconSize: 24,
          ),
          if (showLastSlot)
            HeaderAction(
              key: const ValueKey('locate-button'),
              icon: followReplay
                  ? const Icon(Icons.center_focus_strong)
                  : locating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location),
              label: followReplay
                  ? strings.followReplayLabel
                  : (locating ? strings.locating : strings.locateLabel),
              tooltip: followReplay
                  ? strings.followReplayTooltip
                  : strings.locateTooltip,
              onTap: (locating && !followReplay) ? null : onLocate,
              width: 56,
              iconSize: 24,
            ),
        ],
      ),
    );
  }
}

/// The record cluster pill: the camera action on top, then the record
/// button with Stop directly above it once paused (and while running). It
/// sits on the map edge *opposite* the [MapControlPill], vertically
/// centered — big and away from the other controls, sized for a handlebar
/// mount (see `MapPage`).
///
/// The record slot only shows once a session could actually start: the
/// page passes [gpsWorking] (a real fix arrived via its silent poll or a
/// locate) — a record button on a GPS-less platform would be a dead
/// button. While a session runs the slot holds Pause; once paused it
/// reads Resume and a Stop action appears before it, asking the track's
/// name before it finalizes (discarding from the same dialog is
/// two-step, confirmed).
///
/// The camera action rides the same gate: with no fix there is nothing to
/// tag a photo with, so the button would be a dead one. It stays while a
/// session runs (a photo on a ride is the point) and its position is the
/// session's live fix then (see `MapPage._takePhoto`).
class RecordCluster extends StatefulWidget {
  const RecordCluster({
    super.key,
    required this.model,
    required this.gpsWorking,
    this.onTakePhoto,
  });

  final AppModel model;

  /// True once a real position fix has arrived on this device.
  final bool gpsWorking;

  /// The camera action; null hides the button (a platform without a
  /// camera path, or no fix to tag a photo with).
  final VoidCallback? onTakePhoto;

  @override
  RecordClusterState createState() => RecordClusterState();
}

class RecordClusterState extends State<RecordCluster> {
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
    showMapToast(context, strings.recordDeclined);
  }

  /// Stop: asks what to call the track first (the dialog defaults to the
  /// current date-time timestamp). Save finalizes and imports; Discard —
  /// after a confirmation, it destroys the staged track irreversibly —
  /// ends the session importing nothing; a cancelled dialog leaves the
  /// session recording.
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
            TextButton(
              key: const ValueKey('stop-discard'),
              // The empty string is the discard sentinel: it aliases the
              // name field's "cleared" value, so it never collides with a
              // name result.
              onPressed: () => Navigator.of(context).pop(''),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(strings.discardLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                controller.text.trim().isEmpty
                    ? defaultName
                    : controller.text.trim(),
              ),
              child: Text(strings.saveLabel),
            ),
          ],
        );
      },
    );
    if (!mounted || name == null) return; // Cancelled: keep recording.
    if (name.isEmpty) {
      // Discard is two-step: it destroys the session's whole track —
      // ask before doing it.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.discardConfirmTitle),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const ValueKey('stop-discard-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(strings.discardLabel),
            ),
          ],
        ),
      );
      if (!context.mounted || confirmed != true) return;
      await widget.model.discardRecording();
      return;
    }
    await widget.model.stopRecording(name: name);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final model = widget.model;
    final recording = model.isRecording;
    final paused = model.recording?.state == RecordingState.paused;
    return Material(
      key: const ValueKey('record-cluster'),
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      // Horizontal padding keeps the captions clear of the rounded border.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onTakePhoto != null)
              HeaderAction(
                key: const ValueKey('camera-button'),
                icon: const Icon(Icons.photo_camera_outlined),
                label: strings.cameraLabel,
                tooltip: strings.cameraTooltip,
                onTap: widget.onTakePhoto,
                width: 56,
                iconSize: 24,
              ),
            if (recording)
              HeaderAction(
                icon: const Icon(Icons.stop),
                label: strings.stopLabel,
                tooltip: strings.stopLabel,
                onTap: _stopRecording,
                width: 56,
                iconSize: 24,
              ),
            if (widget.gpsWorking || recording)
              HeaderAction(
                icon: Icon(
                  recording
                      ? (paused ? Icons.play_arrow : Icons.pause)
                      : Icons.fiber_manual_record,
                ),
                label: recording
                    ? (paused ? strings.resumeLabel : strings.pauseLabel)
                    : strings.recordLabel,
                tooltip: recording
                    ? (paused ? strings.resumeLabel : strings.pauseLabel)
                    : strings.recordLabel,
                onTap: recording
                    ? (paused ? model.resumeRecording : model.pauseRecording)
                    : _startRecording,
                width: 56,
                iconSize: 24,
              ),
          ],
        ),
      ),
    );
  }
}
