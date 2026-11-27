/// The tracks drawer: the catalog ordered most-recent-first, its tiles
/// with visibility, an aggregated color dot, the ⋮ menu (Info / Delete /
/// Export) and swipe delete.
library;

import 'package:material_ui/material_ui.dart';

import '../l10n/app_strings.dart';
import '../storage/track_store.dart';
import 'app_model.dart';
import 'format.dart';
import 'track_colors.dart' show exploredAreaColor;

class TrackDrawer extends StatelessWidget {
  const TrackDrawer({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    // Display order: most recent first (startTimeUtc descending,
    // timestamp-less tracks last), original catalog position breaking
    // ties so same-start tracks keep their import order.
    final orderedTracks = [
      for (var i = 0; i < model.tracks.length; i++) (i, model.tracks[i]),
    ];
    orderedTracks.sort((a, b) {
      final aStart = a.$2.startTimeUtc;
      final bStart = b.$2.startTimeUtc;
      if (aStart == null && bStart == null) return a.$1.compareTo(b.$1);
      if (aStart == null) return 1;
      if (bStart == null) return -1;
      final byTime = bStart.compareTo(aStart);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return Drawer(
      width: 360,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Text(
                    strings.tracksLabel,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  Text(
                    '${model.tracks.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  IconButton(
                    tooltip: model.allTracksVisible
                        ? strings.deselectAllTracks
                        : strings.selectAllTracks,
                    icon: Icon(
                      model.allTracksVisible ? Icons.deselect : Icons.done_all,
                    ),
                    onPressed: model.tracks.isEmpty
                        ? null
                        : () => model.setAllVisibleWithFeedback(
                            !model.allTracksVisible,
                          ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: model.tracks.isEmpty
                  ? Center(child: Text(strings.nothingImportedYet))
                  : ListView.builder(
                      // Most recent first: startTimeUtc descending,
                      // timestamp-less tracks last. The original catalog
                      // position breaks ties — List.sort gives no
                      // stability guarantee, and same-start tracks must
                      // keep their import order. Display order only; the
                      // catalog and the index stay as imported.
                      itemCount: orderedTracks.length,
                      itemBuilder: (context, i) {
                        final t = orderedTracks[i].$2;
                        return _TrackTile(model: model, track: t);
                      },
                    ),
            ),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.model, required this.track});

  final AppModel model;
  final StoredTrack track;

  /// The confirmation both destructive entry points (swipe and button)
  /// share: one accidental gesture must not destroy the track. A cancel
  /// or bar dismissal is a no-op; the drawer stays open and the list
  /// updates the moment the delete lands. Returns whether the user
  /// confirmed — [Dismissible.confirmDismiss] consumes the same signal.
  Future<bool> _confirmDelete(BuildContext context, AppStrings strings) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(strings.deleteConfirmTitle(track.name)),
            content: Text(strings.deleteConfirmBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(strings.deleteConfirmCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(strings.deleteConfirmGo),
              ),
            ],
          ),
        ) ==
        true;
  }

  /// Whether the track can be replayed: a track with no timestamp span
  /// is a shape, not a timeline — the menu shows the entry greyed
  /// instead of offering a control that can only fail.
  bool get _replayable =>
      track.durationSeconds != null && track.durationSeconds! > 0;

  /// The average speed in km/h: distance over moving time when the track
  /// has one (same precedence as the recording dashboard), over the total
  /// duration otherwise. Null when neither side is known or positive —
  /// never a fabricated 0 or infinity.
  double? _avgSpeed() {
    final moving = track.movingSeconds;
    final seconds =
        (moving != null && moving > 0) ? moving : track.durationSeconds;
    if (seconds == null || seconds <= 0) return null;
    return track.distanceMeters / seconds * 3.6;
  }

  /// The info dialog: start date/time, format, point count, distance,
  /// duration, moving time and the average speed over the moving time —
  /// values the catalog already carries, never recomputed from the file on
  /// disk (that would re-read and re-parse just to draw a dialog). The close
  /// label reuses the existing Cancel string.
  void _showInfo(BuildContext context, AppStrings strings) {
    final duration = track.durationSeconds;
    final avg = _avgSpeed() == null
        ? '—'
        : '${_avgSpeed()!.toStringAsFixed(1)} km/h';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(track.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(
              strings.infoStart,
              track.startTimeUtc == null
                  ? '—'
                  : strings.trackStart(track.startTimeUtc!),
            ),
            _infoRow(strings.infoFormat, track.format),
            _infoRow(strings.infoPoints, track.pointCount.toString()),
            _infoRow(
              strings.infoDistance,
              formatDistance(track.distanceMeters),
            ),
            _infoRow(
              strings.infoDuration,
              duration == null
                  ? '—'
                  : formatDuration(Duration(seconds: duration.round())),
            ),
            _infoRow(
              strings.infoMovingTime,
              track.movingSeconds == null
                  ? '—'
                  : formatDuration(
                      Duration(seconds: track.movingSeconds!.round())),
            ),
            _infoRow(strings.infoAvgSpeed, avg),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.deleteConfirmCancel),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.ofContext(context);
    final distance = formatDistance(track.distanceMeters);
    final duration = track.durationSeconds == null
        ? '—'
        : formatDuration(Duration(seconds: track.durationSeconds!.round()));
    return Dismissible(
      key: ValueKey('track-${track.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      // The swipe only dismisses after a confirmation; a declined dialog
      // leaves the tile in place and nothing deleted.
      confirmDismiss: (_) => _confirmDelete(context, strings),
      onDismissed: (_) => model.delete(track),
      // A plain ListTile, not a CheckboxListTile: that one wires the
      // whole tile to the checkbox's toggler, so no tap could ever mean
      // anything else. Here the tile's tap — name or the row below —
      // jumps the camera to the track's own points, and the checkbox is
      // the tile's only selecting/hiding element (its own hit target
      // wins the gesture arena); the ⋮ menu likewise stays its own.
      child: ListTile(
        dense: true,
        onTap: () => model.fitTrack(track),
        title: Row(
          children: [
            // The aggregate color the map draws for this track's cluster
            // (palette rank or the per-aggregate override); hidden tracks
            // have no aggregate and show the default.
            Container(
              key: ValueKey('track-dot-${track.id}'),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: exploredAreaColor(model.tintKeyForTrack(track))
                    .withValues(alpha: 1),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: Text(
          '${track.format} · ${strings.pointCount(track.pointCount)} · '
          '$distance · $duration',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The tile's only selecting/hiding element: toggling it
            // shows or hides the track on the map; nothing else in the
            // tile does.
            Checkbox(
              value: track.visible,
              onChanged: (_) => model.toggleVisible(track),
            ),
            // Discoverable next to the swipe-to-delete on touch
            // devices; there is no swipe equivalent with a mouse on
            // the desktop. The menu carries the rest of the per-track
            // surface: Info and Export live there, Delete stays here
            // (one confirmation flow for both the swipe and the entry
            // — see [_confirmDelete]).
            PopupMenuButton<String>(
              key: ValueKey('track-menu-${track.id}'),
              tooltip: strings.trackMenuTooltip,
              icon: const Icon(Icons.more_vert),
              onSelected: (entry) async {
                switch (entry) {
                  case 'info':
                    _showInfo(context, strings);
                  case 'playback':
                    // Close the drawer first: the replay happens on the map,
                    // and the drawer's scrim would sit over it. The popup
                    // menu pops itself after this returns.
                    Scaffold.of(context).closeEndDrawer();
                    model.startPlayback(track);
                  case 'delete':
                    if (await _confirmDelete(context, strings)) {
                      await model.delete(track);
                    }
                  case 'export':
                    // Capture the messenger up front: the export awaits, and
                    // using the context across that gap would.
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      final target = await model.exportTrack(track);
                      // Android's share sheet has no destination path; a
                      // desktop cancellation returns null without a toast.
                      if (target != null) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(strings.exportDone),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    } on Exception {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(strings.exportFailed),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'info',
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 18),
                      const SizedBox(width: 10),
                      Text(strings.trackMenuInfo),
                    ],
                  ),
                ),
                // The replay entry is gated twice over on purpose: a track
                // without timestamps has no timeline to walk, and a running
                // recording owns the follow-camera (the model-side start also
                // refuses such tracks — the menu gate is the visible one).
                PopupMenuItem(
                  value: 'playback',
                  enabled: _replayable && !model.isRecording,
                  child: Row(
                    children: [
                      const Icon(Icons.play_arrow, size: 18),
                      const SizedBox(width: 10),
                      Text(strings.trackMenuPlayback),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      const Icon(Icons.delete_outline, size: 18),
                      const SizedBox(width: 10),
                      Text(strings.deleteTrack),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Row(
                    children: [
                      const Icon(Icons.ios_share, size: 18),
                      const SizedBox(width: 10),
                      Text(strings.trackMenuExport),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
