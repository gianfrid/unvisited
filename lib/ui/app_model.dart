import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:latlong2/latlong.dart';

import '../storage/track_store.dart';
import 'track_colors.dart';

/// Distance threshold in meters for deduplicating nearby points when merging tracks.
/// GPS accuracy is typically 3-10m for consumer devices, so 2m is a safe threshold.
const _mergeDedupeDistanceMeters = 2.0;

/// A track prepared for drawing on the map.
class MapTrack {
  const MapTrack({required this.meta, required this.points, required this.color});

  final StoredTrack meta;
  final List<LatLng> points;
  final Color color;
}

class ImportSummary {
  ImportSummary()
      : imported = 0,
        duplicates = 0,
        skipped = 0,
        failed = 0;

  int imported;
  int duplicates;
  int skipped;
  int failed;

  void add(ImportResult r) {
    switch (r.reason) {
      case 'duplicate':
        duplicates++;
      case null:
        imported++;
      default:
        if (r.reason!.startsWith('skipped:')) {
          skipped++;
        } else {
          failed++;
        }
    }
  }

  bool get isEmpty => imported + duplicates + skipped + failed == 0;

  @override
  String toString() {
    final parts = <String>[];
    if (imported > 0) parts.add('$imported imported');
    if (duplicates > 0) parts.add('$duplicates duplicates');
    if (skipped > 0) parts.add('$skipped skipped');
    if (failed > 0) parts.add('$failed failed');
    return parts.isEmpty ? 'Nothing to import' : parts.join(', ');
  }
}

/// UI state root: owns the store, caches parsed polylines, exposes actions.
class AppModel extends ChangeNotifier {
  AppModel(this.store);

  final TrackStore store;
  final _pointCache = <String, List<LatLng>>{};

  List<StoredTrack> get tracks => store.tracks;

  bool _busy = false;
  bool get busy => _busy;

  /// Whether to merge all visible tracks into a single polyline for rendering.
  /// Defaults to true for better performance and cleaner visualization.
  bool _mergeTracks = true;
  bool get mergeTracks => _mergeTracks;

  /// All points from all visible tracks, merged and deduplicated.
  /// Only valid when [mergeTracks] is true.
  List<LatLng>? _mergedPointsCache;
  int _mergedPointsEpoch = 0;

  /// Points of the tracks added by the most recent import operation, so the
  /// map can refit its camera on what was just imported. [importEpoch] is
  /// bumped on every change; readers compare it against the epoch they last
  /// handled.
  List<LatLng> lastImportedPoints = const [];
  int importEpoch = 0;

  void _noteImported(List<LatLng> out, ImportResult result) {
    final data = result.data;
    if (!result.imported || data == null || data.isEmpty) return;
    out.addAll(data.points.map((p) => LatLng(p.lat, p.lon)));
  }

  Future<void> load() async {
    await store.load();
    notifyListeners();
  }

  /// Reads a picked file (or share-intent temp file) through the pipeline.
  Future<void> importFromFile(String path, {String? name}) async {
    final newPoints = <LatLng>[];
    _busy = true;
    notifyListeners();
    try {
      final f = File(path);
      final result = store.importBytes(f.readAsBytesSync(),
          filename: name ?? path);
      _noteImported(newPoints, result);
      if (result.imported) _pointCache.remove(result.track!.id);
      notifyListeners();
    } finally {
      _recordNewImports(newPoints);
      _busy = false;
      notifyListeners();
    }
  }

  void _recordNewImports(List<LatLng> newPoints) {
    if (newPoints.isEmpty) return;
    lastImportedPoints = newPoints;
    importEpoch++;
  }

  /// Recursively imports every supported track file below [directoryPath]
  /// (SAF-picked folder mapped to a real path by the picker).
  Future<ImportSummary> importFromDirectory(String directoryPath) async {
    final summary = ImportSummary();
    final newPoints = <LatLng>[];
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return summary;
    await for (final entry
        in dir.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final ext = name.toLowerCase().split('.').last;
      if (!const {'gpx', 'fit', 'kmz', 'kml', 'tcx'}.contains(ext)) {
        continue;
      }
      try {
        final result =
            store.importBytes(entry.readAsBytesSync(), filename: name);
        _noteImported(newPoints, result);
        summary.add(result);
      } on Exception {
        summary.failed++;
      }
    }
    _pointCache.clear();
    _recordNewImports(newPoints);
    notifyListeners();
    return summary;
  }

  /// Opens the SAF folder picker and imports every supported file below the
  /// chosen folder. Returns null when the user cancelled.
  Future<ImportSummary?> importViaDirectoryPicker() async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return null;
    return importFromDirectory(dir);
  }

  /// Opens the system file picker and imports the chosen files.
  Future<ImportSummary> importViaFilePicker() async {
    final summary = ImportSummary();
    final newPoints = <LatLng>[];
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gpx', 'fit', 'kmz', 'kml', 'tcx'],
    );
    for (final pf in picked) {
      final path = pf.path;
      if (path == null) continue;
      try {
        final result = store.importBytes(File(path).readAsBytesSync(),
            filename: pf.name);
        _noteImported(newPoints, result);
        summary.add(result);
      } on Exception {
        summary.failed++;
      }
    }
    _pointCache.clear();
    _recordNewImports(newPoints);
    notifyListeners();
    return summary;
  }

  List<MapTrack> get visibleTracks {
    final out = <MapTrack>[];
    for (final t in store.tracks) {
      if (!t.visible) continue;
      var pts = _pointCache[t.id];
      if (pts == null) {
        final data = store.loadPoints(t);
        if (data == null) continue;
        pts = data.points.map((p) => LatLng(p.lat, p.lon)).toList();
        _pointCache[t.id] = pts;
      }
      if (pts.isEmpty) continue;
      out.add(MapTrack(meta: t, points: pts, color: colorForTrack(t.id)));
    }
    return out;
  }

  Future<void> toggleVisible(StoredTrack t) async {
    await store.setVisible(t, !t.visible);
    notifyListeners();
  }

  Future<void> delete(StoredTrack t) async {
    await store.remove(t);
    _pointCache.remove(t.id);
    notifyListeners();
  }

  /// All points of all visible tracks, for fitting the camera.
  List<LatLng> get allVisiblePoints =>
      visibleTracks.expand((t) => t.points).toList();

  /// Toggles between merged and individual track rendering modes.
  void toggleMergeTracks() {
    _mergeTracks = !_mergeTracks;
    _mergedPointsCache = null; // Invalidate cache
    notifyListeners();
  }

  /// Returns the merged, deduplicated points for all visible tracks.
  /// This concatenates all track points into a single list for camera fitting.
  /// Note: For rendering, use [mergedTrackSegments] to avoid artificial connections.
  List<LatLng> get mergedPoints {
    // Check cache validity
    final currentEpoch = _computeEpoch();
    if (_mergedPointsCache != null && _mergedPointsEpoch == currentEpoch) {
      return _mergedPointsCache!;
    }

    final allPoints = <LatLng>[];
    for (final segment in mergedTrackSegments) {
      allPoints.addAll(segment);
    }

    _mergedPointsCache = allPoints;
    _mergedPointsEpoch = currentEpoch;
    return allPoints;
  }

  /// Computes a cache epoch based on visible tracks and their point caches.
  int _computeEpoch() {
    var epoch = 0;
    for (final t in store.tracks) {
      if (t.visible) {
        epoch ^= t.id.hashCode;
        if (_pointCache.containsKey(t.id)) {
          epoch ^= _pointCache[t.id]!.length;
        }
      }
    }
    return epoch;
  }

  /// Returns deduplicated points for a single track, skipping points that are
  /// too close to the previous point (within [_mergeDedupeDistanceMeters]).
  List<LatLng> _deduplicateTrack(List<LatLng> trackPoints) {
    if (trackPoints.isEmpty) return const [];

    final deduplicated = <LatLng>[];
    final distance = const Distance();

    for (final point in trackPoints) {
      if (deduplicated.isEmpty) {
        deduplicated.add(point);
      } else {
        final last = deduplicated.last;
        final dist = distance(last, point);
        if (dist >= _mergeDedupeDistanceMeters) {
          deduplicated.add(point);
        }
        // else: skip this point, it's too close to the last point
      }
    }

    return deduplicated;
  }

  /// Returns all visible tracks with deduplicated points.
  /// Each track is kept separate to avoid creating artificial connections
  /// between unrelated tracks.
  List<List<LatLng>> get mergedTrackSegments {
    final allSegments = <List<LatLng>>[];
    for (final t in store.tracks) {
      if (!t.visible) continue;
      var pts = _pointCache[t.id];
      if (pts == null) {
        final data = store.loadPoints(t);
        if (data == null) continue;
        pts = data.points.map((p) => LatLng(p.lat, p.lon)).toList();
        _pointCache[t.id] = pts;
      }
      if (pts.isNotEmpty) {
        allSegments.add(_deduplicateTrack(pts));
      }
    }
    return allSegments;
  }
}
