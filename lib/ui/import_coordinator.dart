import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:latlong2/latlong.dart';

import '../host_channel.dart';
import '../l10n/app_strings.dart';
import '../road/road_matcher.dart';
import '../storage/track_store.dart';
import 'fog_of_war.dart' show unlockCenters;

/// Counters for one import operation, turned into user-facing text by
/// [describe] with the caller's locale: this class is UI state, not a
/// place to bake in English.
class ImportSummary {
  ImportSummary() : imported = 0, duplicates = 0, skipped = 0, failed = 0;

  int imported;
  int duplicates;
  int skipped;
  int failed;

  void add(ImportResult r) {
    switch (r.outcome) {
      case ImportSucceeded():
        imported++;
      case ImportDuplicate():
        duplicates++;
      case ImportSkipped():
        skipped++;
      case ImportFailed():
        failed++;
    }
  }

  bool get isEmpty => imported + duplicates + skipped + failed == 0;

  /// The summary as one line of user-facing text.
  String describe(AppStrings strings) {
    final parts = <String>[
      if (imported > 0) strings.importedCount(imported),
      if (duplicates > 0) strings.duplicateCount(duplicates),
      if (skipped > 0) strings.skippedCount(skipped),
      if (failed > 0) strings.failedCount(failed),
    ];
    return parts.isEmpty ? strings.nothingToImport : parts.join(', ');
  }
}

/// The import concern of the app model: every import path (single file,
/// directory walk, SAF tree, platform pickers, finalized recordings)
/// collapses onto one helper — [importBytes] — performing the shared
/// store + roads + point-cache + summary choreography.
///
/// Not a Listenable itself: [onChanged] forwards notifications to the
/// owning [AppModel].
class ImportCoordinator {
  ImportCoordinator({
    required this.store,
    required this.roadMatcher,
    required this.onChanged,
  });

  final TrackStore store;
  final GeometricRoadMatcher? Function() roadMatcher;
  final void Function() onChanged;

  /// Points of each visible track, cached so the fog overlay does not
  /// re-read the store per frame.
  final _pointCache = <String, List<LatLng>>{};

  bool _busy = false;
  bool get busy => _busy;

  /// Points of the tracks added by the most recent import operation, so the
  /// map can refit its camera on what was just imported. [importEpoch] is
  /// bumped on every change; readers compare it against the epoch they last
  /// handled.
  List<LatLng> lastImportedPoints = const [];
  int importEpoch = 0;

  List<LatLng>? cachedPoints(StoredTrack t) => _pointCache[t.id];
  void rememberPoints(StoredTrack t, List<LatLng> pts) => _pointCache[t.id] = pts;
  void invalidateCache(String trackId) => _pointCache.remove(trackId);
  void clearCache() => _pointCache.clear();

  void _noteImported(List<LatLng> out, ImportResult result) {
    final data = result.data;
    if (!result.imported || data == null || data.isEmpty) return;
    out.addAll(data.points.map((p) => LatLng(p.lat, p.lon)));
  }

  void _recordNewImports(List<LatLng> newPoints) {
    if (newPoints.isEmpty) return;
    lastImportedPoints = newPoints;
    importEpoch++;
  }

  /// Computes road unlock state for a freshly imported track and persists
  /// it on the catalog entry. No-op without an active road file — the
  /// overlay stays circles-only and the index field stays absent. Matching
  /// runs on the same cell-coalesced unlock centers the circles use, so
  /// roads and circles always tell the same story.
  void _matchRoads(ImportResult result) {
    final matcher = roadMatcher();
    final data = result.data;
    if (!result.imported || matcher == null || data == null) return;
    final match = matcher.match(
      unlockCenters(data.points.map((p) => LatLng(p.lat, p.lon))),
    );
    if (match.corridors.isNotEmpty) {
      store.saveUnlockedWays(result.track!, match.corridors);
    }
  }

  /// The one import helper: runs bytes through the unified pipeline
  /// (store), matches road corridors, accumulates the camera-refit points
  /// and the summary counters. Used by every import path and by recording
  /// finalize/salvage.
  void importBytes(
    List<int> bytes,
    String name,
    ImportSummary summary,
    List<LatLng> newPoints,
  ) {
    final result = store.importBytes(bytes, filename: name);
    _noteImported(newPoints, result);
    _matchRoads(result);
    summary.add(result);
  }

  /// Imports finalized recording bytes (a deliberate stop, or a salvage)
  /// through the unified pipeline: a recorded track is an ordinary
  /// catalog track — dedup, fog and road corridors all apply — and the
  /// point cache is invalidated so the overlay picks the points up.
  ImportResult importRecordingBytes(List<int> bytes, String filename) {
    final result = store.importBytes(bytes, filename: filename);
    if (result.imported) invalidateCache(result.track!.id);
    _matchRoads(result);
    onChanged();
    return result;
  }
  /// Reads a picked file (or share-intent temp file) through the pipeline.
  Future<void> importFromFile(String path, {String? name}) async {
    final newPoints = <LatLng>[];
    _busy = true;
    onChanged();
    try {
      final f = File(path);
      final result = store.importBytes(
        f.readAsBytesSync(),
        filename: name ?? path,
      );
      _noteImported(newPoints, result);
      _matchRoads(result);
      if (result.imported) invalidateCache(result.track!.id);
      onChanged();
    } finally {
      _recordNewImports(newPoints);
      _busy = false;
      onChanged();
    }
  }

  /// Recursively imports every supported track file below [directoryPath]
  /// (platform-picker folder on desktop, where directories are real paths).
  Future<ImportSummary> importFromDirectory(String directoryPath) async {
    final summary = ImportSummary();
    final newPoints = <LatLng>[];
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return summary;
    await for (final entry in dir.list(recursive: true, followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      final ext = name.toLowerCase().split('.').last;
      if (!const {'gpx', 'fit', 'kmz', 'kml', 'tcx'}.contains(ext)) {
        continue;
      }
      try {
        importBytes(entry.readAsBytesSync(), name, summary, newPoints);
      } on Exception {
        summary.failed++;
      }
    }
    clearCache();
    _recordNewImports(newPoints);
    onChanged();
    return summary;
  }

  /// Opens the SAF folder picker and imports every supported file below the
  /// chosen folder (Android), or opens the platform directory picker
  /// (desktop, where the host channel is missing and picked folders are real
  /// paths dart:io can walk). Returns null when the user cancelled.
  Future<ImportSummary?> importViaDirectoryPicker() async {
    final String? treeUri;
    try {
      treeUri = await hostChannel.invokeMethod<String>('pickDirectory');
    } on MissingPluginException {
      // Desktop run: no host-side implementation, fall through to
      // file_picker's platform portal directory picker.
      final dir = await FilePicker.getDirectoryPath();
      if (dir == null) return null;
      return importFromDirectory(dir);
    }
    if (treeUri == null) return null; // user cancelled
    return _importSafTree(treeUri);
  }

  /// Android SAF folder import. The system tree picker grants access to a
  /// content:// tree URI — no storage permission can grant raw-path access
  /// to it (scoped storage killed that on Android 13+, and USB-OTG providers
  /// never had real paths). The host channel scans the tree and copies the
  /// supported files into a staging directory; the unified pipeline consumes
  /// those bytes and the staged copies are deleted again.
  Future<ImportSummary> _importSafTree(String treeUri) async {
    final summary = ImportSummary();
    final newPoints = <LatLng>[];
    _busy = true;
    onChanged();
    try {
      final staged =
          await hostChannel.invokeListMethod<Map<Object?, Object?>>(
            'listTrackFiles',
            treeUri,
          ) ??
          const <Map<Object?, Object?>>[];
      for (final entry in staged) {
        final path = entry['path'] as String?;
        final name = entry['name'] as String?;
        if (path == null || name == null) continue;
        final file = File(path);
        try {
          importBytes(file.readAsBytesSync(), name, summary, newPoints);
        } on Exception {
          summary.failed++;
        } finally {
          try {
            file.deleteSync();
          } on Exception {
            // Staging lives in the app cache dir; a leftover is harmless.
          }
        }
      }
    } finally {
      clearCache();
      _recordNewImports(newPoints);
      _busy = false;
      onChanged();
    }
    return summary;
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
        importBytes(File(path).readAsBytesSync(), pf.name, summary, newPoints);
      } on Exception {
        summary.failed++;
      }
    }
    clearCache();
    _recordNewImports(newPoints);
    onChanged();
    return summary;
  }
}
