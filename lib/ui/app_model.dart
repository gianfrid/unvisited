import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:latlong2/latlong.dart';

import '../storage/track_store.dart';
import 'track_colors.dart';

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

  Future<void> load() async {
    await store.load();
    notifyListeners();
  }

  /// Reads a picked file (or share-intent temp file) through the pipeline.
  Future<void> importFromFile(String path, {String? name}) async {
    _busy = true;
    notifyListeners();
    try {
      final f = File(path);
      final result = store.importBytes(f.readAsBytesSync(),
          filename: name ?? path);
      if (result.imported) _pointCache.remove(result.track!.id);
      notifyListeners();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Recursively imports every supported track file below [directoryPath]
  /// (SAF-picked folder mapped to a real path by the picker).
  Future<ImportSummary> importFromDirectory(String directoryPath) async {
    final summary = ImportSummary();
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
        summary.add(result);
      } on Exception {
        summary.failed++;
      }
    }
    _pointCache.clear();
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
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gpx', 'fit', 'kmz', 'kml', 'tcx'],
    );
    for (final pf in picked) {
      final path = pf.path;
      if (path == null) continue;
      try {
        summary.add(store.importBytes(File(path).readAsBytesSync(),
            filename: pf.name));
      } on Exception {
        summary.failed++;
      }
    }
    _pointCache.clear();
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
}
