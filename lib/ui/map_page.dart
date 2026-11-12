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

  static const _berlinCenter = LatLng(52.5200, 13.4050);
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
    // Start silently with the last saved position (never prompting) and
    // let a live fix override it once it arrives. With no location
    // permission granted yet this is a no-op — only the locate button
    // asks.
    _silentPositionUpdate();
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

  /// Centers the map on the last saved position while waiting for a live
  /// fix (and moves onto the fix once it arrives). Never asks for
  /// permission; when none is granted or the platform has no location
  /// support (desktop Linux) this leaves the camera where it was.
  Future<void> _silentPositionUpdate() async {
    final pos = await widget.model.currentPosition(prompt: false);
    if (!mounted || pos == null) return;
    // Saved tracks fit the whole catalog; only the empty map follows the
    // position so imports and track fits are never fought over.
    if (widget.model.visibleTracks.isNotEmpty) return;
    _mapController.move(pos, _mapController.camera.zoom);
  }

  /// Locate button: prompts for permission when none has been granted
  /// and centers the map on the current position.
  Future<void> _locate() async {
    final pos = await widget.model.currentPosition(prompt: true);
    if (!mounted) return;
    if (pos == null) {
      _toast('Location unavailable — permission denied or no fix');
      return;
    }
    _mapController.move(pos, _mapController.camera.zoom);
  }

  /// One entry point for imports: single files and folder scans flow
  /// through the same unified pipeline, so one button is enough.
  Future<void> _chooseImport() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Track files'),
              subtitle: const Text('GPX, FIT, KMZ or TCX — one or more'),
              onTap: () => Navigator.of(context).pop('files'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('A folder'),
              subtitle:
                  const Text('Every supported file below it is imported'),
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
    final summary = await widget.model.importViaFilePicker();
    _toast(summary.toString());
  }

  /// Settings sheet: About card (build date) and the delete-all action.
  Future<void> _openSettings() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => _SettingsSheet(
        trackCount: widget.model.tracks.length,
        versionFuture: widget.versionFuture,
      ),
    );
    if (!mounted || choice != 'deleteAll') return;
    final trackCount = widget.model.tracks.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all tracks?'),
        content: Text(
          'This permanently deletes all $trackCount stored tracks. '
          'The original files you imported them from are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await widget.model.deleteAll();
    _toast('All tracks deleted');
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
          color: mergedTrackColor,
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
            tooltip: 'Import tracks',
            icon: const Icon(Icons.add),
            onPressed: _chooseImport,
          ),
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
            tooltip: 'Fit tracks',
            icon: const Icon(Icons.zoom_out_map),
            onPressed: mapTracks.isEmpty ? null : _fitTracks,
          ),
          IconButton(
            tooltip: 'Center on current position',
            icon: const Icon(Icons.my_location),
            onPressed: _locate,
          ),
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Tracks',
              icon: const _BadgeIcon(),
              onPressed: () => Scaffold.of(context).openEndDrawer(),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      endDrawerEnableOpenDragGesture: false,
      endDrawer: TrackDrawer(
        model: widget.model,
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              // Start at the last saved position (Berlin as the very first
              // run fallback); a live fix refines this after startup.
              initialCenter: widget.model.savedPosition ?? _berlinCenter,
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
                // The default flutter_map logo badge is redundant next to
                // the OSM attribution this app already shows.
                showFlutterMapAttribution: false,
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

/// Bottom sheet hosting all app settings: an About card (build date) and
/// the destructive delete-all entry.
class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({required this.trackCount, this.versionFuture});

  final int trackCount;

  /// Build time shown in the About card; tests inject a fixed value so
  /// no git process is spawned from a widget test.
  final Future<String>? versionFuture;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Settings',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Unvisited',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  const Text('Local-only track viewer for GPX, FIT, KMZ '
                      'and TCX files on OpenStreetMap.'),
                  const SizedBox(height: 8),
                  FutureBuilder<String>(
                    future: versionFuture ?? AppVersion.resolve(),
                    builder: (context, snapshot) => Text(
                      'Build date: ${snapshot.data ?? '...'}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).hintColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('Delete all tracks'),
            subtitle: Text(
              trackCount == 0 ? 'No stored tracks' : '$trackCount stored',
            ),
            enabled: trackCount > 0,
            onTap: () => Navigator.of(context).pop('deleteAll'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
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
