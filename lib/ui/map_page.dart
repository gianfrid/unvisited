import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../storage/track_store.dart';
import '../tile_source.dart';
import '../build_version.dart';
import 'app_model.dart';
import 'track_colors.dart';

class MapPage extends StatefulWidget {
  const MapPage(
      {super.key,
      required this.model,
      required this.cacheDir,
      this.versionFuture});

  final AppModel model;
  final Directory cacheDir;

  /// Build time shown in the drawer footer; tests inject a fixed value so
  /// no git process is spawned from a widget test.
  final Future<String>? versionFuture;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  int _seenImportEpoch = 0;

  static const _startCenter = LatLng(52.5200, 13.4050); // Berlin
  static const _startZoom = 13.0;
  static const _fitPadding = EdgeInsets.all(64);

  @override
  void initState() {
    super.initState();
    _seenImportEpoch = widget.model.importEpoch;
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
  }

  late final bool _cacheUsable;

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
    widget.model.removeListener(_onModelChanged);
    super.dispose();
  }

  void _onModelChanged() {
    if (!mounted) return;
    final epoch = widget.model.importEpoch;
    if (epoch != _seenImportEpoch) {
      _seenImportEpoch = epoch;
      final pts = widget.model.lastImportedPoints;
      if (pts.isNotEmpty) {
        // Center on what was just imported.
        _fitWhenSized(CameraFit.coordinates(
          coordinates: pts,
          padding: _fitPadding,
        ));
      }
    }
    // Invalidate merged points cache when tracks change visibility
    if (widget.model.mergeTracks) {
      widget.model.mergedPoints; // Access to update cache
    }
    setState(() {});
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

  void _fitTracks() {
    final pts = widget.model.mergeTracks
        ? widget.model.mergedPoints
        : widget.model.allVisiblePoints;
    if (pts.isEmpty) return;
    _fitWhenSized(
        CameraFit.coordinates(coordinates: pts, padding: _fitPadding));
  }

  Future<void> _pickFolder() async {
    try {
      final summary = await widget.model.importViaDirectoryPicker();
      if (summary != null) _toast(summary.toString());
    } on PlatformException catch (e) {
      _toast('Folder import failed: ${e.message ?? e.code}');
    }
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

  List<Polyline> _buildMergedPolyline(List<MapTrack> tracks) {
    if (tracks.isEmpty) return [];
    final segments = widget.model.mergedTrackSegments;
    if (segments.isEmpty) return [];
    
    return [
      for (final segment in segments)
        Polyline(
          points: segment,
          color: singleTrackColor,
          strokeWidth: 3.5,
          borderStrokeWidth: 1,
          borderColor: Colors.black38,
        ),
    ];
  }

  List<Polyline> _buildIndividualPolylines(List<MapTrack> tracks) {
    return [
      for (final t in tracks)
        Polyline(
          points: t.points,
          color: t.color,
          strokeWidth: 3.5,
          borderStrokeWidth: 1,
          borderColor: Colors.black38,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mapTracks = widget.model.visibleTracks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Unvisited'),
        actions: [
          IconButton(
            tooltip: 'Zoom in (Ctrl+ or Ctrl+MouseWheel)',
            icon: const Icon(Icons.zoom_in),
            onPressed: () {
              final camera = _mapController.camera;
              _mapController.move(camera.center, camera.zoom + 1);
            },
          ),
          IconButton(
            tooltip: 'Zoom out (Ctrl- or Ctrl+MouseWheel)',
            icon: const Icon(Icons.zoom_out),
            onPressed: () {
              final camera = _mapController.camera;
              _mapController.move(camera.center, camera.zoom - 1);
            },
          ),
          IconButton(
            tooltip: 'Toggle merged/split tracks',
            icon: Icon(widget.model.mergeTracks ? Icons.layers : Icons.layers_clear),
            onPressed: widget.model.toggleMergeTracks,
          ),
          IconButton(
            tooltip: widget.model.uniformTrackColor
                ? 'Per-track colors'
                : 'Same color for all tracks',
            icon: Icon(widget.model.uniformTrackColor
                ? Icons.format_color_fill
                : Icons.palette),
            onPressed: widget.model.toggleUniformTrackColor,
          ),
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
      endDrawer: TrackDrawer(
        model: widget.model,
        versionFuture: widget.versionFuture,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _startCenter,
              initialZoom: _startZoom,
              // Startup fit for saved tracks goes through the engine path:
              // flutter_map applies it only once the camera has a real
              // size, guarding against the zero-sized startup constraints
              // of a fresh window surface. A manual post-frame fitCamera
              // here degenerates the camera instead and the map stays
              // grey until the first pan.
              initialCameraFit: mapTracks.isEmpty
                  ? null
                  : CameraFit.coordinates(
                      coordinates: [
                        for (final t in mapTracks) ...t.points,
                      ],
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
            ),
            children: [
              TileLayer(
                urlTemplate: tileUrlTemplate,
                userAgentPackageName: tileUserAgent,
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
              PolylineLayer(
                polylines: widget.model.mergeTracks
                    ? _buildMergedPolyline(mapTracks)
                    : _buildIndividualPolylines(mapTracks),
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
  const TrackDrawer({super.key, required this.model, this.versionFuture});

  final AppModel model;

  /// Build version to show in the footer; tests inject a fixed value so
  /// no git process is spawned from a widget test.
  final Future<String>? versionFuture;

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
                  IconButton(
                    tooltip: model.allTracksVisible
                        ? 'Deselect all tracks'
                        : 'Select all tracks',
                    icon: Icon(model.allTracksVisible
                        ? Icons.deselect
                        : Icons.done_all),
                    onPressed: model.tracks.isEmpty
                        ? null
                        : () =>
                            model.setAllVisible(!model.allTracksVisible),
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
            const Divider(height: 1),
            FutureBuilder<String>(
              future: versionFuture ?? AppVersion.resolve(),
              builder: (context, snapshot) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  snapshot.data ?? '...',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor),
                ),
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
        secondary: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                date.replaceAll(' · ', ''),
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Discoverable next to the swipe-to-delete on touch devices;
            // there is no swipe equivalent with a mouse on the desktop.
            IconButton(
              tooltip: 'Delete track',
              icon: const Icon(Icons.delete_outline),
              visualDensity: VisualDensity.compact,
              onPressed: () => model.delete(track),
            ),
          ],
        ),
        dense: true,
      ),
    );
  }
}
