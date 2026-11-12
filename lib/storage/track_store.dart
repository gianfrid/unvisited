import 'dart:convert';
import 'dart:io';

import '../import/fit_parser.dart';
import '../import/gpx_parser.dart';
import '../import/kmz_parser.dart';
import '../import/tcx_parser.dart';
import '../import/track_importer.dart';
import '../models/track.dart';

/// Catalog entry for a stored track. The original track file lives as
/// `tracks/<contentHash>.<ext>`; this record holds everything the UI needs
/// without re-parsing.
class StoredTrack {
  StoredTrack({
    required this.id,
    required this.name,
    required this.format,
    required this.file,
    required this.pointCount,
    required this.distanceMeters,
    this.startTimeUtc,
    this.visible = true,
  });

  final String id; // content hash (FNV-1a 64-bit hex)
  final String name;
  final String format; // GPX / FIT / KMZ / TCX
  final String file; // relative to the store's tracks directory
  final int pointCount;
  final double distanceMeters;
  final DateTime? startTimeUtc;
  bool visible;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'format': format,
        'file': file,
        'pointCount': pointCount,
        'distanceMeters': distanceMeters,
        'startTimeUtc': startTimeUtc?.toIso8601String(),
        'visible': visible,
      };

  static StoredTrack fromMap(Map<String, dynamic> m) => StoredTrack(
        id: m['id'] as String,
        name: m['name'] as String,
        format: m['format'] as String,
        file: m['file'] as String,
        pointCount: (m['pointCount'] as num).toInt(),
        distanceMeters: (m['distanceMeters'] as num).toDouble(),
        startTimeUtc: m['startTimeUtc'] == null
            ? null
            : DateTime.tryParse(m['startTimeUtc'] as String),
        visible: m['visible'] as bool? ?? true,
      );
}

class ImportResult {
  const ImportResult({
    this.track,
    this.data,
    this.reason,
  });

  /// Null when the import did not produce a new track.
  final StoredTrack? track;

  /// Parsed data for the (new) track; handy so the UI can zoom to it.
  final TrackData? data;

  /// Human-readable explanation when [track] is null: duplicate / skipped /
  /// failed.
  final String? reason;

  bool get imported => track != null;
}

/// Local-only track storage: original files under `tracks/`, catalog in
/// `index.json`. Dedup is content-based (64-bit FNV-1a): the same activity
/// exported both by OpenTracks and re-exported from Strava gets unique
/// bytes and therefore may still appear twice *between* exports, but any
/// byte-identical re-import (the common case) is a no-op.
class TrackStore {
  TrackStore(this.root, {TrackImporter? importer})
      : importer = importer ??
            TrackImporter(parsers: [
              GpxParser(),
              FitParser(),
              KmzParser(),
              TcxParser(),
            ]);

  /// Store root directory (e.g. the app's documents dir).
  final Directory root;
  final TrackImporter importer;

  Directory get tracksDir {
    final d = Directory('${root.path}${Platform.pathSeparator}tracks');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  File get indexFile =>
      File('${root.path}${Platform.pathSeparator}index.json');

  final List<StoredTrack> _tracks = [];

  /// All cataloged tracks, insertion ordered.
  List<StoredTrack> get tracks => List.unmodifiable(_tracks);

  Future<void> load() async {
    _tracks.clear();
    final f = indexFile;
    if (!f.existsSync()) return;
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      final list = (decoded as Map)['tracks'] as List;
      for (final raw in list) {
        try {
          final t = StoredTrack.fromMap(Map<String, dynamic>.from(raw as Map));
          if (File(_pathFor(t)).existsSync()) _tracks.add(t);
        } on Exception {
          // skip broken entries rather than losing the whole catalog
        }
      }
    } on FormatException {
      // corrupt index: start fresh, original files stay on disk
    }
  }

  /// Imports raw track bytes through the unified pipeline.
  ///
  /// * byte-identical duplicate → `ImportResult(duplicate)`; nothing written.
  /// * FIT monitoring / non-activity → `ImportResult(skipped)`.
  /// * parse failure or unknown format → `ImportResult(failed)`.
  ImportResult importBytes(List<int> bytes, {String? filename}) {
    if (_tracks.any((t) => t.id == contentHash(bytes))) {
      return ImportResult(reason: 'duplicate');
    }
    final TrackData data;
    try {
      data = importer.import(bytes, filename: filename);
    } on UnsupportedTrackException catch (e) {
      return ImportResult(reason: 'skipped: ${e.reason}');
    } on TrackParseException catch (e) {
      return ImportResult(reason: 'failed: $e');
    }
    final id = contentHash(bytes);
    final ext = (data.format).toLowerCase();
    final stored = StoredTrack(
      id: id,
      name: data.name,
      format: data.format,
      file: '$id.$ext',
      pointCount: data.points.length,
      distanceMeters: data.distanceMeters,
      startTimeUtc: data.startTime?.toUtc(),
    );
    final target = File(_pathFor(stored));
    target.createSync(recursive: true);
    target.writeAsBytesSync(bytes, flush: true);
    _tracks.add(stored);
    _saveIndex();
    return ImportResult(track: stored, data: data);
  }

  Future<void> remove(StoredTrack track) async {
    _tracks.removeWhere((t) => t.id == track.id);
    final f = File(_pathFor(track));
    if (f.existsSync()) f.deleteSync();
    _saveIndex();
  }

  /// Removes every cataloged track: all files under `tracks/` and all
  /// index entries. The empty index is persisted immediately.
  Future<void> clearAll() async {
    for (final t in _tracks) {
      final f = File(_pathFor(t));
      if (f.existsSync()) f.deleteSync();
    }
    _tracks.clear();
    _saveIndex();
  }

  Future<void> setVisible(StoredTrack track, bool visible) async {
    track.visible = visible;
    _saveIndex();
  }

  /// Sets visibility for every cataloged track in one index write.
  Future<void> setAllVisible(bool visible) async {
    for (final t in _tracks) {
      t.visible = visible;
    }
    _saveIndex();
  }

  /// Loads and parses the stored file for [track] (for map drawing).
  TrackData? loadPoints(StoredTrack track) {
    final f = File(_pathFor(track));
    if (!f.existsSync()) return null;
    try {
      return importer.import(f.readAsBytesSync(), filename: track.name);
    } on TrackParseException {
      return null;
    } on UnsupportedTrackException {
      return null;
    }
  }

  void _saveIndex() {
    final map = {
      'version': 1,
      'tracks': _tracks.map((t) => t.toMap()).toList(),
    };
    root.createSync(recursive: true);
    indexFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(map),
        flush: true);
  }

  String _pathFor(StoredTrack t) =>
      '${tracksDir.path}${Platform.pathSeparator}${t.file}';
}

/// 64-bit FNV-1a content hash, stable across runs and platforms that this
/// app targets (Android/Linux/macOS/Windows VM). Sufficient for
/// personal-scale track deduplication (~10^-11 collision odds for thousands
/// of files); no `package:crypto` dependency needed.
String contentHash(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
