import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:latlong2/latlong.dart';

import '../import/fit_parser.dart';
import '../import/gpx_parser.dart';
import '../import/kmz_parser.dart';
import '../import/tcx_parser.dart';
import '../import/track_importer.dart';
import '../models/track.dart';
import '../road/road_format.dart';
import '../ui/fog_of_war.dart' show defaultFogStyle, fogStyleOrDefault;

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
    this.durationSeconds,
    this.movingSeconds,
    this.visible = true,
  });

  final String id; // content hash (FNV-1a 64-bit hex)
  final String name;
  final String format; // GPX / FIT / KMZ / TCX
  final String file; // relative to the store's tracks directory
  final int pointCount;
  final double distanceMeters;

  /// The track's start time, or null when the file carries none. Older
  /// index entries carry none — [loadPoints] heals it on the first open
  /// (the app's self-healing rule); a file without timestamps stays
  /// null, which is honest, not stale.
  DateTime? startTimeUtc;

  /// Moving-elapsed span of the point timestamps, in seconds. Older
  /// indexes (and tracks without timestamps) carry none; like
  /// [startTimeUtc], [loadPoints] heals it on the first open.
  double? durationSeconds;

  /// Moving time of the track in seconds (gaps at or above the shared
  /// moving-speed threshold, segment breaks excluded). Null for tracks
  /// without usable timestamps; healed by [loadPoints] like
  /// [durationSeconds].
  double? movingSeconds;

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
        'durationSeconds': durationSeconds,
        'movingSeconds': movingSeconds,
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
        durationSeconds: m['durationSeconds'] == null
            ? null
            : (m['durationSeconds'] as num).toDouble(),
        movingSeconds: m['movingSeconds'] == null
            ? null
            : (m['movingSeconds'] as num).toDouble(),
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

/// What one import attempt did with the bytes. A sealed family so
/// consumers switch over it exhaustively instead of matching on the
/// reason string.
sealed class ImportOutcome {
  const ImportOutcome();
}

/// A new track was written to the catalog.
final class ImportSucceeded extends ImportOutcome {
  const ImportSucceeded();
}

/// The bytes (or the same activity re-exported) are already cataloged.
final class ImportDuplicate extends ImportOutcome {
  const ImportDuplicate();
}

/// Deliberately not imported (e.g. a FIT monitoring file).
final class ImportSkipped extends ImportOutcome {
  const ImportSkipped(this.reason);

  final String reason;
}

/// Parsing or persisting failed.
final class ImportFailed extends ImportOutcome {
  const ImportFailed(this.error);

  final Object error;
}

class ImportResult {
  const ImportResult({
    this.track,
    this.data,
    this.outcome = const ImportSucceeded(),
  });

  /// Null when the import did not produce a new track.
  final StoredTrack? track;

  /// Parsed data for the (new) track; handy so the UI can zoom to it.
  final TrackData? data;

  /// What the pipeline did with the bytes.
  final ImportOutcome outcome;

  bool get imported => outcome is ImportSucceeded;
}

/// Local-only track storage: original files under `tracks/`, catalog in
/// `index.json`. Dedup is content-based: byte-identical re-imports (the
/// common case) dedup by the 64-bit FNV-1a content hash, and the same
/// activity exported once as FIT and once as GPX is caught by the
/// cross-format rule — matching start time (±2 s) and total distance
/// (within 10%) together count as a duplicate; either signal alone
/// never dedups, and a track without a start time is only caught by
/// the byte hash.
/// The persisted user preferences — the index's `settings` entry as one
/// value object. Immutable: a save builds a new snapshot and persists the
/// index, so settings are never observed half-updated. A save survives
/// [TrackStore.clearAll]: preferences are the user's, not catalog content.
class AppSettings {
  const AppSettings({
    this.tint = 'green',
    this.recordingTint = 'red',
    this.zoomSliderSide = 'right',
    this.language = 'system',
    this.themeMode = 'system',
    this.tileLayer = 'standard',
    this.fogStyle = defaultFogStyle,
    this.mapRotation = 'north',
    this.keepScreenOn = true,
    this.debugLogging = false,
    this.showUnvisitedRoads = true,
    this.roadsFile,
    this.aggregateColors = const {},
  });

  final String tint;
  final String recordingTint;

  /// Which screen edge the control pill hugs ('zoomSliderSide' is the
  /// historical JSON key): 'left' or 'right'.
  final String zoomSliderSide;

  /// UI language: 'system' (follow the device) or a language code such as
  /// 'it'. Stored as a raw string so an unknown value from a hand-edited
  /// index can never break startup — the UI falls back to the system
  /// language for anything it does not recognize.
  final String language;

  /// Theme mode: 'system' (follow the device), 'light', or 'dark'.
  final String themeMode;

  /// Base tile style: 'standard' (OSM raster) or 'cycle' (CyclOSM).
  final String tileLayer;

  /// Exploration overlay display style ('circles', 'polyline' or 'ink') —
  /// how the unlocked fog reads over the tiles. Normalized (unknown
  /// values fall back) on read; see fog_of_war.dart.
  final String fogStyle;

  /// The recording follow-camera's rotation mode: 'north' (the default —
  /// the map stays north-up) or 'course' (course-up, where below the
  /// low-speed gate the compass takes over the rotation). Legacy stored
  /// values 'off'/'on' and the removed 'compass' mode migrate to
  /// 'north'/'course' in [AppSettings.fromMap].
  final String mapRotation;

  /// Whether the screen stays on while recording (the default). Applied
  /// live by the recording dashboard — even mid-session — through the
  /// host channel's window flag.
  final bool keepScreenOn;

  /// Whether the in-app debug log accumulates (Settings -> "Debug
  /// logging", default off). While off, logging calls are no-ops.
  final bool debugLogging;

  /// Whether the unvisited-roads presentation draws (Settings ->
  /// "Show unvisited roads", default on): the dashed overlay and the
  /// coverage chip. While off the whole coverage pass is skipped — no
  /// geometry decode per settle — and both disappear from the map.
  final bool showUnvisitedRoads;

  /// The side-loaded road region file's *name* (relative to `roads/` under
  /// the root), or null when none is set. The app owns a copy of the file;
  /// see `TrackStore.adoptRoadFile`.
  final String? roadsFile;

  /// Per-aggregate color overrides, keyed by the aggregate's anchor track
  /// id — content hashes that survive re-imports, so the override survives
  /// membership changes.
  final Map<String, String> aggregateColors;

  /// Legacy rotation values ('off'/'on', from before the named modes) map
  /// to 'north'/'course'; anything else falls back to the 'north' default.
  static String _migrateMapRotation(String? v) => switch (v) {
        'on' => 'course',
        'off' => 'north',
        // The removed explicit compass mode: course mode now contains
        // its low-speed compass takeover.
        'compass' => 'course',
        _ => v ?? 'north',
      };

  /// Tolerant read: a missing or malformed field falls back to the
  /// default, so even a hand-edited index cannot break startup.
  factory AppSettings.fromMap(Map<dynamic, dynamic> m) => AppSettings(
        tint: (m['tint'] as String?) ?? 'green',
        recordingTint: (m['recordingTint'] as String?) ?? 'red',
        zoomSliderSide: (m['zoomSliderSide'] as String?) ?? 'right',
        language: (m['language'] as String?) ?? 'system',
        themeMode: (m['themeMode'] as String?) ?? 'system',
        tileLayer: (m['tileLayer'] as String?) ?? 'standard',
        fogStyle: (m['fogStyle'] as String?) ?? defaultFogStyle,
        mapRotation: _migrateMapRotation(m['mapRotation'] as String?),
        keepScreenOn: (m['keepScreenOn'] as bool?) ?? true,
        debugLogging: (m['debugLogging'] as bool?) ?? false,
        showUnvisitedRoads: (m['showUnvisitedRoads'] as bool?) ?? true,
        roadsFile: m['roadsFile'] as String?,
        aggregateColors:
            (m['aggregateColors'] as Map<Object?, Object?>? ?? {})
                .map((k, v) => MapEntry(k as String, v as String)),
      );

  AppSettings copyWith({
    String? tint,
    String? recordingTint,
    String? zoomSliderSide,
    String? language,
    String? themeMode,
    String? tileLayer,
    String? fogStyle,
    String? mapRotation,
    bool? keepScreenOn,
    bool? debugLogging,
    bool? showUnvisitedRoads,
    String? roadsFile,
    bool clearRoadsFile = false,
    Map<String, String>? aggregateColors,
  }) =>
      AppSettings(
        tint: tint ?? this.tint,
        recordingTint: recordingTint ?? this.recordingTint,
        zoomSliderSide: zoomSliderSide ?? this.zoomSliderSide,
        language: language ?? this.language,
        themeMode: themeMode ?? this.themeMode,
        tileLayer: tileLayer ?? this.tileLayer,
        fogStyle: fogStyle ?? this.fogStyle,
        mapRotation: mapRotation ?? this.mapRotation,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        debugLogging: debugLogging ?? this.debugLogging,
        showUnvisitedRoads: showUnvisitedRoads ?? this.showUnvisitedRoads,
        roadsFile:
            clearRoadsFile ? null : roadsFile ?? this.roadsFile,
        aggregateColors: aggregateColors ?? this.aggregateColors,
      );

  /// The index's `settings` entry, in the field names `load` reads.
  Map<String, Object?> toMap() => {
        'tint': tint,
        'zoomSliderSide': zoomSliderSide,
        'language': language,
        'themeMode': themeMode,
        'tileLayer': tileLayer,
        'fogStyle': fogStyle,
        'mapRotation': mapRotation,
        'keepScreenOn': keepScreenOn,
        'debugLogging': debugLogging,
        'showUnvisitedRoads': showUnvisitedRoads,
        'recordingTint': recordingTint,
        if (roadsFile != null) 'roadsFile': roadsFile,
        if (aggregateColors.isNotEmpty)
          'aggregateColors': Map<String, String>.of(aggregateColors),
      };
}

class TrackStore {
  TrackStore(this.root, {TrackImporter? importer})
      : importer = importer ??
            TrackImporter(parsers: [
              GpxParser(),
              FitParser(),
              KmzParser(),
              TcxParser(),
              KmlParser(KmzParser()),
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

  /// The persisted user preferences — one [AppSettings] snapshot in the
  /// index. The getters below delegate; saving produces a new snapshot
  /// (see `_apply`).
  AppSettings _settings = const AppSettings();

  /// Last known device position (map start center), restored from the index.
  /// Null when the app has never obtained a fix. Its own top-level index
  /// key: the user's location, not a settings-sheet preference.
  double? _lastPositionLat;
  double? _lastPositionLon;
  double? get lastPositionLat => _lastPositionLat;
  double? get lastPositionLon => _lastPositionLon;

  String get tint => _settings.tint;
  String get recordingTint => _settings.recordingTint;
  String get zoomSliderSide => _settings.zoomSliderSide;
  String get language => _settings.language;
  String get themeMode => _settings.themeMode;
  String get tileLayer => _settings.tileLayer;

  /// The normalized fog display style (unknown stored values fall back).
  String get fogStyle => fogStyleOrDefault(_settings.fogStyle);
  String get mapRotation => _settings.mapRotation;
  bool get keepScreenOn => _settings.keepScreenOn;
  bool get debugLogging => _settings.debugLogging;

  /// Whether the dashed unvisited-roads overlay draws (default on).
  bool get showUnvisitedRoads => _settings.showUnvisitedRoads;
  String? get roadsFile => _settings.roadsFile;

  /// Applies a new settings snapshot and persists the index.
  Future<void> _apply(AppSettings s) async {
    _settings = s;
    _saveIndex();
  }

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
    final old = _settings.roadsFile;
    final stored = roadFileFor(name);
    if (old != null && old != name) {
      final previous = roadFileFor(old);
      if (previous.existsSync()) previous.deleteSync();
    }
    File(sourcePath).copySync(stored.path);
    _settings = _settings.copyWith(roadsFile: name);
    _saveIndex();
    return stored.path;
  }

  /// Forgets the road region and deletes its stored copy. Unlock state
  /// already recorded on tracks survives: it is exploration data (the
  /// matched corridors are materialized polylines), not cache.
  Future<void> clearRoadsFile() async {
    final old = _settings.roadsFile;
    _settings = _settings.copyWith(clearRoadsFile: true);
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
  Future<void> saveTint(String tint) async =>
      _apply(_settings.copyWith(tint: tint));

  Future<void> saveZoomSliderSide(String side) async =>
      _apply(_settings.copyWith(zoomSliderSide: side));

  /// Saves the UI language choice ('system' or a language code). A
  /// preference like the tint: it survives [clearAll].
  Future<void> saveLanguage(String language) async =>
      _apply(_settings.copyWith(language: language));

  /// Saves the theme mode choice ('system', 'light', or 'dark').
  Future<void> saveThemeMode(String mode) async =>
      _apply(_settings.copyWith(themeMode: mode));

  /// Saves the base tile style choice ('standard' or 'cycle').
  Future<void> saveTileLayer(String layer) async =>
      _apply(_settings.copyWith(tileLayer: layer));

  /// Saves the exploration overlay's display style ('circles', 'polyline'
  /// or 'ink').
  Future<void> saveFogStyle(String style) async =>
      _apply(_settings.copyWith(fogStyle: style));

  /// Saves whether the recording follow-camera rotates course-up
  /// ('on' or 'off'; 'off' keeps the map north-up).
  Future<void> saveMapRotation(String rotation) async =>
      _apply(_settings.copyWith(mapRotation: rotation));

  /// Saves whether the screen stays on while recording (default on).
  Future<void> saveKeepScreenOn(bool on) async =>
      _apply(_settings.copyWith(keepScreenOn: on));

  /// Saves whether the in-app debug log accumulates (default off).
  Future<void> saveDebugLogging(bool on) async =>
      _apply(_settings.copyWith(debugLogging: on));

  /// Saves whether the dashed unvisited-roads overlay draws (default
  /// on); the coverage chip is not affected.
  Future<void> saveShowUnvisitedRoads(bool on) async =>
      _apply(_settings.copyWith(showUnvisitedRoads: on));

  /// Saves the live recording trace's tint key.
  Future<void> saveRecordingTint(String tint) async =>
      _apply(_settings.copyWith(recordingTint: tint));

  String? aggregateColor(String anchorId) =>
      _settings.aggregateColors[anchorId];

  /// Saves the color override for the aggregate anchored at [anchorId] (an
  /// empty [tintKey] clears it), persisted in the index with the rest of
  /// the settings.
  Future<void> saveAggregateColor(String anchorId, String tintKey) async {
    final colors = Map.of(_settings.aggregateColors);
    if (tintKey.isEmpty) {
      colors.remove(anchorId);
    } else {
      colors[anchorId] = tintKey;
    }
    await _apply(_settings.copyWith(aggregateColors: colors));
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
      if (settings is Map) _settings = AppSettings.fromMap(settings);
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
  /// * byte-identical duplicate → `ImportResult(ImportDuplicate())`;
  ///   nothing written.
  /// * FIT monitoring / non-activity → `ImportResult(ImportSkipped(..))`.
  /// * parse failure or unknown format → `ImportResult(ImportFailed(..))`.
  ImportResult importBytes(List<int> bytes, {String? filename}) {
    if (_tracks.any((t) => t.id == contentHash(bytes))) {
      return const ImportResult(outcome: ImportDuplicate());
    }
    final TrackData data;
    try {
      data = importer.import(bytes, filename: filename);
    } on UnsupportedTrackException catch (e) {
      return ImportResult(outcome: ImportSkipped(e.reason));
    } on TrackParseException catch (e) {
      return ImportResult(outcome: ImportFailed(e));
    }
    if (_findNearDuplicate(data) != null) {
      // Same activity in different bytes (e.g. one export as FIT, another
      // as GPX): counts as a duplicate like a byte-identical re-import.
      return const ImportResult(outcome: ImportDuplicate());
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
      durationSeconds: data.durationSeconds,
      movingSeconds: data.movingSeconds,
    );
    final target = File(_pathFor(stored));
    target.createSync(recursive: true);
    target.writeAsBytesSync(bytes, flush: true);
    _tracks.add(stored);
    _saveIndex();
    return ImportResult(track: stored, data: data);
  }

  // --- Catalog export/import ----------------------------------------------

  /// The whole catalog as one zip: `index.json` plus every file under
  /// `tracks/`. Compression comes from the already-bundled `archive`
  /// package, so nothing is added to the APK.
  Uint8List exportCatalogBytes() {
    final archive = Archive();
    if (indexFile.existsSync()) {
      archive.addFile(
        ArchiveFile('index.json', indexFile.lengthSync(), indexFile.readAsBytesSync()),
      );
    }
    for (final f in tracksDir.listSync().whereType<File>()) {
      archive.addFile(
        ArchiveFile('tracks/${f.uri.pathSegments.last}', f.lengthSync(), f.readAsBytesSync()),
      );
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Re-imports every track file inside an export zip through the unified
  /// pipeline (content-hash dedup applies, so re-importing the same export
  /// adds nothing). Returns the count of newly imported tracks. Throws
  /// [FormatException] when the zip is not an Unvisited export.
  int importCatalogBytes(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (!archive.files.any((f) => f.name == 'index.json')) {
      throw const FormatException('not an Unvisited export (no index.json)');
    }
    var imported = 0;
    for (final f in archive.files) {
      if (!f.isFile || !f.name.startsWith('tracks/')) continue;
      final result = importBytes(
        f.content as List<int>,
        filename: f.name.split('/').last,
      );
      if (result.imported) imported++;
    }
    return imported;
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

  /// Loads and parses the stored file for [track] (for map drawing) —
  /// the one place a stored track is "opened", so it is also where a
  /// legacy catalog entry self-heals: an index written before the
  /// timeline fields existed keeps null in them although the file has
  /// timestamps, and every metadata consumer (the info dialog, the
  /// playback gate) would refuse a replayable track. The parsed data is
  /// already in hand here, so the heal is free: fill what is missing,
  /// persist once — a set value is never overwritten (the index is the
  /// record of what was true at import), and a timeline-less track keeps
  /// null, which is honest rather than fabricated.
  TrackData? loadPoints(StoredTrack track) {
    final f = File(_pathFor(track));
    if (!f.existsSync()) return null;
    TrackData data;
    try {
      data = importer.import(f.readAsBytesSync(), filename: track.name);
    } on TrackParseException {
      return null;
    } on UnsupportedTrackException {
      return null;
    }
    var healed = false;
    if (track.startTimeUtc == null && data.startTime != null) {
      track.startTimeUtc = data.startTime!.toUtc();
      healed = true;
    }
    if (track.durationSeconds == null && data.durationSeconds != null) {
      track.durationSeconds = data.durationSeconds;
      healed = true;
    }
    if (track.movingSeconds == null && data.movingSeconds != null) {
      track.movingSeconds = data.movingSeconds;
      healed = true;
    }
    if (healed) _saveIndex();
    return data;
  }

  void _saveIndex() {
    final map = {
      'version': 1,
      'tracks': _tracks.map((t) => t.toMap()).toList(),
      if (_lastPositionLat != null && _lastPositionLon != null)
        'lastPosition': {'lat': _lastPositionLat, 'lon': _lastPositionLon},
      'settings': _settings.toMap(),
    };
    root.createSync(recursive: true);
    indexFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(map),
        flush: true);
  }

  String _pathFor(StoredTrack t) =>
      '${tracksDir.path}${Platform.pathSeparator}${t.file}';

  /// The stored file of a track, as imported (never rewritten on the way
  /// out — export ships the very bytes the catalog keeps).
  File trackFileFor(StoredTrack t) => File(_pathFor(t));
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
