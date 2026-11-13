import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';

import '../import/fit_parser.dart';
import '../import/gpx_parser.dart';
import '../import/kmz_parser.dart';
import '../import/tcx_parser.dart';
import '../import/track_importer.dart';
import '../models/track.dart';
import '../road/road_format.dart';

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

  /// Road unlock state: OSM way id → the matched corridor sub-polylines
  /// (see `lib/road/road_matcher.dart`). Persisted as polyline5 strings;
  /// computed at import time when a road file is active; empty when no
  /// road data is present. Lives on the track, so deleting the track
  /// deletes its unlock state with it.
  Map<String, List<List<LatLng>>> unlockedWays = {};

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'format': format,
        'file': file,
        'pointCount': pointCount,
        'distanceMeters': distanceMeters,
        'startTimeUtc': startTimeUtc?.toIso8601String(),
        'visible': visible,
        // Written only when non-empty: indexes from before road matching
        // (and tracks imported without road data) stay unchanged.
        if (unlockedWays.isNotEmpty)
          'unlockedWays': {
            for (final entry in unlockedWays.entries)
              entry.key: [
                for (final corridor in entry.value)
                  encodePolyline5(
                      [for (final p in corridor) (p.latitude, p.longitude)]),
              ],
          },
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
      )
        ..unlockedWays = _unlockedWaysFrom(m['unlockedWays']);

  /// Tolerates a missing or malformed field: an old index (or a hand-edited
  /// one) must never break startup.
  static Map<String, List<List<LatLng>>> _unlockedWaysFrom(dynamic raw) {
    if (raw is! Map) return {};
    final out = <String, List<List<LatLng>>>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! List) continue;
      final corridors = <List<LatLng>>[];
      for (final encoded in entry.value as List) {
        if (encoded is! String) continue;
        try {
          corridors.add([
            for (final (lat, lon) in decodePolyline5(encoded))
              LatLng(lat, lon),
          ]);
        } on RoadFormatException {
          // A corrupt corridor is dropped, not fatal.
        }
      }
      if (corridors.isNotEmpty) out[entry.key as String] = corridors;
    }
    return out;
  }
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

  /// Last known device position (map start center), restored from the index.
  /// Null when the app has never obtained a fix.
  double? _lastPositionLat;
  double? _lastPositionLon;
  double? get lastPositionLat => _lastPositionLat;
  double? get lastPositionLon => _lastPositionLon;

  /// Overlay tint key (see the exploration tints in the UI). Persisted in
  /// the index like the last position: a user preference, not track data.
  String _tint = 'green';
  String get tint => _tint;

  /// Which screen edge the zoom slider hugs: 'left' or 'right'.
  String _zoomSliderSide = 'right';
  String get zoomSliderSide => _zoomSliderSide;

  /// UI language: 'system' (follow the device) or a language code such as
  /// 'it'. Stored as a raw string so an unknown value from a hand-edited
  /// index can never break startup - the UI falls back to the system
  /// language for anything it does not recognize.
  String _language = 'system';
  String get language => _language;

  /// Theme mode: 'system' (follow the device), 'light', or 'dark'.
  /// Persisted in the index like other preferences.
  String _themeMode = 'system';
  String get themeMode => _themeMode;

  /// The side-loaded road region file's *name* (relative to `roads/` under
  /// the root), or null when none is set. The picked file is copied into
  /// the store root on activation — a picked path's access can be revoked
  /// or its file deleted later, so the app owns its copy instead.
  String? _roadsFile;
  String? get roadsFile => _roadsFile;

  Directory get _roadsDir =>
      Directory('${root.path}${Platform.pathSeparator}roads')
        ..createSync(recursive: true);

  /// The store's own copy of the region file named [name].
  File roadFileFor(String name) =>
      File('${_roadsDir.path}${Platform.pathSeparator}$name');

  /// Copies a picked `.unvisited-roads` file into the app root (replacing
  /// a previous region's copy) and records its name in the index. Returns
  /// the stored copy's path.
  String adoptRoadFile(String sourcePath) {
    final name = File(sourcePath).uri.pathSegments.last;
    final old = _roadsFile;
    final stored = roadFileFor(name);
    if (old != null && old != name) {
      final previous = roadFileFor(old);
      if (previous.existsSync()) previous.deleteSync();
    }
    File(sourcePath).copySync(stored.path);
    _roadsFile = name;
    _saveIndex();
    return stored.path;
  }

  /// Forgets the road region and deletes its stored copy. Unlock state
  /// already recorded on tracks survives: it is exploration data (the
  /// matched corridors are materialized polylines), not cache.
  Future<void> clearRoadsFile() async {
    final old = _roadsFile;
    _roadsFile = null;
    if (old != null) {
      final previous = roadFileFor(old);
      if (previous.existsSync()) previous.deleteSync();
    }
    _saveIndex();
  }

  /// Saves the device position as the map start center for next launch.
  /// This survives [clearAll]: it is the user's location, not track data.
  Future<void> savePosition(double lat, double lon) async {
    _lastPositionLat = lat;
    _lastPositionLon = lon;
    _saveIndex();
  }

  /// Saves the exploration overlay tint. Survives [clearAll] like the
  /// position: a preference, not catalog content.
  Future<void> saveTint(String tint) async {
    _tint = tint;
    _saveIndex();
  }

  Future<void> saveZoomSliderSide(String side) async {
    _zoomSliderSide = side;
    _saveIndex();
  }

  /// Saves the UI language choice ('system' or a language code). A
  /// preference like the tint: it survives [clearAll].
  Future<void> saveLanguage(String language) async {
    _language = language;
    _saveIndex();
  }

  /// Saves the theme mode choice ('system', 'light', or 'dark').
  Future<void> saveThemeMode(String mode) async {
    _themeMode = mode;
    _saveIndex();
  }

  Future<void> load() async {
    _tracks.clear();
    final f = indexFile;
    if (!f.existsSync()) return;
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      final map = decoded as Map;
      final pos = map['lastPosition'];
      if (pos is Map) {
        _lastPositionLat = (pos['lat'] as num?)?.toDouble();
        _lastPositionLon = (pos['lon'] as num?)?.toDouble();
      }
      final settings = map['settings'];
      if (settings is Map) {
        _tint = (settings['tint'] as String?) ?? _tint;
        _zoomSliderSide =
            (settings['zoomSliderSide'] as String?) ?? _zoomSliderSide;
        _language = (settings['language'] as String?) ?? _language;
        _themeMode = (settings['themeMode'] as String?) ?? _themeMode;
        _roadsFile = settings['roadsFile'] as String?;
      }
      final list = map['tracks'] as List;
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
    if (_findNearDuplicate(data) != null) {
      // Same activity in different bytes (e.g. one export as FIT, another
      // as GPX): counts as a duplicate like a byte-identical re-import.
      return ImportResult(reason: 'duplicate');
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

  /// The stored track that [data] describes in different bytes, or null.
  ///
  /// Cross-format dedup heuristic (SPEC: the same activity exported once
  /// as FIT and once as GPX has different bytes and different names, so
  /// the content hash cannot catch it). Two signals together, both cheap:
  /// the start time (an activity starts once, however it is encoded) and
  /// the total distance (re-sampling changes point counts, not length by
  /// much). Either signal alone would false-positive — two people can
  /// start a ride at the same second.
  StoredTrack? _findNearDuplicate(TrackData data) {
    final start = data.startTime?.toUtc();
    if (start == null) return null;
    for (final t in _tracks) {
      final other = t.startTimeUtc;
      if (other == null) continue;
      if (start.difference(other).abs() > _sameActivityStartTolerance) {
        continue;
      }
      final scale = t.distanceMeters > data.distanceMeters
          ? t.distanceMeters
          : data.distanceMeters;
      final diff = (t.distanceMeters - data.distanceMeters).abs();
      // The 1 m floor keeps two tiny (sub-meter) tracks comparable.
      if (diff / (scale > 1 ? scale : 1) <= _sameActivityDistanceTolerance) {
        return t;
      }
    }
    return null;
  }

  /// Start times within this window count as the same activity start:
  /// formats round timestamps differently (FIT stores whole seconds, some
  /// writers drift a beat).
  static const _sameActivityStartTolerance = Duration(seconds: 2);

  /// Total distance within this relative tolerance counts as the same
  /// route; re-sampling between formats shifts it, but not by a tenth.
  static const _sameActivityDistanceTolerance = 0.10;

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

  /// Persists a track's road unlock state (way id → matched corridor
  /// sub-polylines), computed by the model's matcher at import time. A
  /// preference-adjacent catalog field: it survives like the rest of the
  /// track entry and is deleted with the track.
  void saveUnlockedWays(
      StoredTrack track, Map<String, List<List<LatLng>>> corridors) {
    track.unlockedWays = {
      for (final entry in corridors.entries)
        entry.key: List.of(entry.value),
    };
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
      if (_lastPositionLat != null && _lastPositionLon != null)
        'lastPosition': {'lat': _lastPositionLat, 'lon': _lastPositionLon},
      'settings': {
        'tint': _tint,
        'zoomSliderSide': _zoomSliderSide,
        'language': _language,
        'themeMode': _themeMode,
        if (_roadsFile != null) 'roadsFile': _roadsFile,
      },
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
