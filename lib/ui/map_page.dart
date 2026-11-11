import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../storage/track_store.dart';
import 'app_model.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key, required this.model});

  final AppModel model;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  bool _didFitTracks = false;

  static const _startCenter = LatLng(52.5200, 13.4050); // Berlin
  static const _startZoom = 13.0;

  @override
  void didUpdateWidget(covariant MapPage old) {
    super.didUpdateWidget(old);
    _scheduleFit();
  }

  void _scheduleFit() {
    final pts = widget.model.allVisiblePoints;
    if (_didFitTracks || pts.isEmpty) return;
    _didFitTracks = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitTracks());
  }

  void _fitTracks() {
    final pts = widget.model.allVisiblePoints;
    if (pts.isEmpty) return;
    _mapController.fitCamera(
      CameraFit.coordinates(coordinates: pts, padding: EdgeInsets.all(64)),
    );
  }

  Future<void> _pickFolder() async {
    final summary = await widget.model.importViaDirectoryPicker();
    if (summary != null) _toast(summary.toString());
  }

  Future<void> _pickFiles() async {
    final summary = await widget.model.importViaFilePicker();
    _toast(summary.toString());
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final mapTracks = widget.model.visibleTracks;
    _scheduleFit();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unvisited'),
        actions: [
          IconButton(
            tooltip: 'Fit tracks',
            icon: const Icon(Icons.zoom_out_map),
            onPressed: mapTracks.isEmpty ? null : _fitTracks,
          ),
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Tracks',
              icon: const _BadgeIcon(),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawerEnableOpenDragGesture: false,
      endDrawer: TrackDrawer(model: widget.model),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: _startCenter,
              initialZoom: _startZoom,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'dev.unvisited.app',
              ),
              PolylineLayer(
                polylines: [
                  for (final t in mapTracks)
                    Polyline(
                      points: t.points,
                      color: t.color,
                      strokeWidth: 3.5,
                      borderStrokeWidth: 1,
                      borderColor: Colors.black38,
                    ),
                ],
              ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () {},
                  ),
                ],
              ),
            ],
          ),
          if (mapTracks.isEmpty)
            const Center(
              child: _EmptyHint(),
            ),
          if (widget.model.busy)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'folder',
            tooltip: 'Import a folder (SAF)',
            onPressed: _pickFolder,
            child: const Icon(Icons.folder_open),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'files',
            tooltip: 'Import track files',
            onPressed: _pickFiles,
            icon: const Icon(Icons.add),
            label: const Text('Import'),
          ),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.route, size: 40),
            const SizedBox(height: 8),
            Text(
              'No tracks yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: const Text(
                'Import GPX, FIT, KMZ or TCX files — pick a folder or '
                'single files, or share a track from another app.',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BadgeIcon extends StatelessWidget {
  const _BadgeIcon();

  @override
  Widget build(BuildContext context) => const Icon(Icons.stacked_line_chart);
}

class TrackDrawer extends StatelessWidget {
  const TrackDrawer({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
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
                    'Tracks',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  Text(
                    '${model.tracks.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: model.tracks.isEmpty
                  ? const Center(child: Text('Nothing imported yet'))
                  : ListView.builder(
                      itemCount: model.tracks.length,
                      itemBuilder: (context, i) {
                        final t = model.tracks[i];
                        return _TrackTile(
                          model: model,
                          track: t,
                        );
                      },
                    ),
            ),
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

  @override
  Widget build(BuildContext context) {
    final distance = track.distanceMeters >= 1000
        ? '${(track.distanceMeters / 1000).toStringAsFixed(track.distanceMeters >= 10000 ? 0 : 1)} km'
        : '${track.distanceMeters.round()} m';
    final date = track.startTimeUtc == null
        ? ''
        : ' · ${track.startTimeUtc!.toLocal().toIso8601String().split('T').first}';
    return Dismissible(
      key: ValueKey('track-${track.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => model.delete(track),
      child: CheckboxListTile(
        value: track.visible,
        onChanged: (_) => model.toggleVisible(track),
        title: Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${track.format} · ${track.pointCount} pts · $distance',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        secondary: Text(
          date.replaceAll(' · ', ''),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        dense: true,
      ),
    );
  }
}
