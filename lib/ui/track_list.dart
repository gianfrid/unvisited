/// The tracks drawer: the catalog ordered most-recent-first, its tiles
/// with visibility, swipe/button delete.
library;

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../storage/track_store.dart';
import 'app_model.dart';
import 'format.dart';

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
                        : () => model.setAllVisible(!model.allTracksVisible),
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
      child: CheckboxListTile(
        value: track.visible,
        onChanged: (_) => model.toggleVisible(track),
        title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${track.format} · ${strings.pointCount(track.pointCount)} · '
          '$distance · $duration',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // Discoverable next to the swipe-to-delete on touch devices;
        // there is no swipe equivalent with a mouse on the desktop. The
        // menu carries the rest of the per-track surface: Info and
        // Export live there, Delete stays here (one confirmation flow
        // for both the swipe and the entry — see [_confirmDelete]).
        secondary: PopupMenuButton<String>(
          key: ValueKey('track-menu-${track.id}'),
          tooltip: strings.trackMenuTooltip,
          icon: const Icon(Icons.more_vert),
          onSelected: (entry) async {
            switch (entry) {
              case 'delete':
                if (await _confirmDelete(context, strings)) {
                  await model.delete(track);
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
        dense: true,
      ),
    );
  }
}
