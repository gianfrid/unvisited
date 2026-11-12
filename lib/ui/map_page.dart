import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../storage/track_store.dart';
import '../tile_source.dart';
import '../build_version.dart';
import 'app_model.dart';
import 'fog_of_war.dart';
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

/// OSM standard tiles exist between zoom 0 and 19; 3 is a world view that
/// still feels like a map. Both the camera and the zoom slider stay inside.
const _minZoom = 3.0;
const _maxZoom = 19.0;

class _MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  StreamSubscription<MapEvent>? _mapEvents;
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
    // Cross a zoom level: the fog coarseness is keyed to the zoom, so the
    // overlay must be rebuilt when the view moves between zoom levels
    // (the cell grid doubles per band — see fogCellSizeFor).
    _mapEvents = _mapController.mapEventStream.listen((event) {
      final cell = fogCellSizeFor(
          zoom: event.camera.zoom, latitude: event.camera.center.latitude);
      if (cell != _fogCellSize) {
        setState(() => _fogCellSize = cell);
      }
    });
    // Start silently with the last saved position (never prompting) and
    // let a live fix override it once it arrives. With no location
    // permission granted yet this is a no-op — only the locate button
    // asks.
    _silentPositionUpdate();
  }

  late final bool _cacheUsable;

  /// Current fog-cell edge for the explored overlay; updated from map
  /// events in initState and read when the circles are built.
  double _fogCellSize = baseCellSizeMeters;

  /// Cached unlock centers keyed to the current overlay inputs (visible
  /// track ids + cell size), so pans and transient item rebuilds do not
  /// re-walk every track point.
  String? _fogCentersKey;
  List<LatLng> _fogCenters = const [];

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
    final pts = widget.model.allVisiblePoints;
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

  /// Fog-of-war overlay: one translucent circle per unlocked grid cell, in
  /// the single exploration tint. Track polylines are gone by design — the
  /// union of circles is how a visited area shows on the map.
  List<CircleMarker> _buildFogCircles(List<MapTrack> tracks) {
    final key =
        '${[for (final t in tracks) t.meta.id].join('|')}@$_fogCellSize';
    if (key != _fogCentersKey) {
      _fogCentersKey = key;
      _fogCenters = unlockCenters(
        tracks.expand((t) => t.points),
        cellSizeMeters: _fogCellSize,
      );
    }
    final radius = unlockRadiusForCell(_fogCellSize);
    final tint = exploredAreaColor(widget.model.trackTint);
    return [
      for (final c in _fogCenters)
        CircleMarker(
          point: c,
          color: tint,
          radius: radius,
          useRadiusInMeter: true,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mapTracks = widget.model.visibleTracks;
    return Scaffold(
      // No app bar: the labeled actions live on a compact floating
      // toolbar that hugs its content at the top-right corner, so the
      // map map keeps rendering behind it instead of being pushed down
      // by a full-width bar.
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
              minZoom: _minZoom,
              maxZoom: _maxZoom,
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
              CircleLayer(
                circles: _buildFogCircles(mapTracks),
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
          // Lateral zoom control on the configured edge (settings).
          // SafeArea: without an app bar the window insets (notches,
          // status bar) are the map's top edge now. On the right it starts
          // below the toolbar band, so the two never overlap on narrow
          // screens (the toolbar is centered and can reach the edges).
          Positioned(
            top: 0,
            left: widget.model.zoomSliderSide == 'left' ? 12 : null,
            right: widget.model.zoomSliderSide == 'left' ? null : 12,
            child: SafeArea(
              minimum: EdgeInsets.only(
                  top: widget.model.zoomSliderSide == 'left'
                      ? 16
                      : kToolbarHeight + 24),
              child: _ZoomSlider(controller: _mapController),
            ),
          ),
          // Compact floating toolbar, centered across the top instead of
          // a full-width app bar.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              minimum: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.topCenter,
                child: _FloatingToolbar(
                  children: [
                  _HeaderAction(
                    icon: const Icon(Icons.add),
                    label: 'Import',
                    tooltip: 'Import tracks',
                    onTap: _chooseImport,
                  ),
                  _HeaderAction(
                    icon: const Icon(Icons.zoom_out_map),
                    label: 'Fit',
                    tooltip: 'Fit tracks',
                    onTap: mapTracks.isEmpty ? null : _fitTracks,
                  ),
                  _HeaderAction(
                    icon: const Icon(Icons.my_location),
                    label: 'Locate',
                    tooltip: 'Center on current position',
                    onTap: _locate,
                  ),
                  Builder(
                    builder: (context) => _HeaderAction(
                      icon: const _BadgeIcon(),
                      label: 'Tracks',
                      tooltip: 'Tracks',
                      onTap: () => Scaffold.of(context).openEndDrawer(),
                    ),
                  ),
                  _HeaderAction(
                    icon: const Icon(Icons.settings_outlined),
                    label: 'Settings',
                    tooltip: 'Settings',
                    onTap: _openSettings,
                  ),
                  ],
                ),
              ),
            ),
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

/// The header as a compact pill that hugs its content, floating above
/// the map at the top-right corner instead of a full-width bar.
class _FloatingToolbar extends StatelessWidget {
  const _FloatingToolbar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(24),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A header action that says what it does: icon over a short caption.
/// Tooltips stay for long-press/hover explanations; the caption alone
/// is meant to make them unnecessary.
class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.onTap,
  });

  final Widget icon;
  final String label;
  final String tooltip;

  /// Null disables the action (see the Fit button on an empty map).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final color = scheme.onSurface.withValues(alpha: enabled ? 1 : 0.38);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 48,
        height: kToolbarHeight,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme.merge(
                data: IconThemeData(size: 20, color: color),
                child: icon,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lateral zoom slider pinned to the map's left edge: step buttons at the
/// ends and a draggable rail whose thumb shows the live zoom level. It
/// tracks every camera change (wheel, pinch, keyboard R/F and double-tap),
/// not just its own input.
class _ZoomSlider extends StatefulWidget {
  const _ZoomSlider({required this.controller});

  final MapController controller;

  @override
  State<_ZoomSlider> createState() => _ZoomSliderState();
}

class _ZoomSliderState extends State<_ZoomSlider> {
  static const _trackExtent = 180.0;
  static const _thumbExtent = 28.0;

  StreamSubscription<MapEvent>? _events;
  double _zoom = _minZoom; // overwritten in initState from the camera

  @override
  void initState() {
    super.initState();
    _zoom = widget.controller.camera.zoom.clamp(_minZoom, _maxZoom);
    // Any camera move (pinch, wheel, fit) updates the thumb's position.
    _events = widget.controller.mapEventStream.listen((event) {
      final zoom = event.camera.zoom.clamp(_minZoom, _maxZoom);
      if (zoom != _zoom) setState(() => _zoom = zoom);
    });
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  void _moveTo(double zoom) {
    final target = zoom.clamp(_minZoom, _maxZoom);
    if (target == _zoom) return;
    final camera = widget.controller.camera;
    widget.controller.move(camera.center, target);
  }

  void _dragTo(Offset localPosition) {
    // Top of the rail is max zoom; dragging up zooms in.
    final fraction =
        (1 - localPosition.dy / _trackExtent).clamp(0.0, 1.0);
    _moveTo(_minZoom + fraction * (_maxZoom - _minZoom));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fraction = (_zoom - _minZoom) / (_maxZoom - _minZoom);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            blurRadius: 6,
            color: Colors.black26,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomStepButton(
            icon: Icons.add,
            tooltip: 'Zoom in',
            onTap: () => _moveTo(_zoom + 1),
          ),
          SizedBox(
            key: const ValueKey('zoom-track'),
            width: 40,
            height: _trackExtent,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (details) =>
                  _dragTo(details.localPosition),
              onVerticalDragUpdate: (details) =>
                  _dragTo(details.localPosition),
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Center(
                    child: Container(
                      width: 4,
                      height: _trackExtent - 8,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: fraction * (_trackExtent - _thumbExtent),
                    child: Container(
                      width: _thumbExtent,
                      height: _thumbExtent,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(blurRadius: 4, color: Colors.black38),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _ZoomStepButton(
            icon: Icons.remove,
            tooltip: 'Zoom out',
            onTap: () => _moveTo(_zoom - 1),
          ),
        ],
      ),
    );
  }
}

class _ZoomStepButton extends StatelessWidget {
  const _ZoomStepButton(
      {required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 18),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        onPressed: onTap,
      ),
    );
  }
}

/// Bottom sheet hosting all app settings: an About card (build date), the
/// map appearance controls and the destructive delete-all entry.
class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet(
      {required this.model,
      required this.trackCount,
      this.versionFuture});

  final AppModel model;
  final int trackCount;

  /// Build time shown in the About card; tests inject a fixed value so
  /// no git process is spawned from a widget test.
  final Future<String>? versionFuture;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
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
          // The appearance controls read the live model, so changes show on
          // the map behind the sheet immediately.
          AnimatedBuilder(
            animation: model,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ListTile(
                  dense: true,
                  title: Text('Track color'),
                  subtitle: Text('Tint of the unlocked areas on the map'),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      for (final entry in explorationTints.entries)
                        _TintSwatch(
                          tintKey: entry.key,
                          color: entry.value,
                          selected: model.trackTint == entry.key,
                          onTap: () => model.setTrackTint(entry.key),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  dense: true,
                  title: const Text('Zoom slider'),
                  subtitle:
                      const Text('Screen edge the zoom slider sits on'),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'left', label: Text('Left')),
                      ButtonSegment(value: 'right', label: Text('Right')),
                    ],
                    selected: {model.zoomSliderSide},
                    onSelectionChanged: (selection) =>
                        model.setZoomSliderSide(selection.first),
                  ),
                ),
              ],
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
      ),
    );
  }
}

/// One selectable tint swatch for the exploration overlay, labeled by
/// its tooltip; the selection ring marks the persisted tint.
class _TintSwatch extends StatelessWidget {
  const _TintSwatch({
    required this.tintKey,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String tintKey;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = tintKey[0].toUpperCase() + tintKey.substring(1);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Tooltip(
        message: name,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: ShapeDecoration(
              shape: CircleBorder(
                side: BorderSide(
                  width: 2,
                  color: selected ? scheme.primary : Colors.transparent,
                ),
              ),
            ),
            child: Center(
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  // The overlay tint is translucent by design; the swatch
                  // shows the solid color it is made from.
                  color: color.withValues(alpha: 1),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
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
