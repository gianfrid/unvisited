import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:geolocator/geolocator.dart';

import '../host_channel.dart';
import '../recording/android_position_source.dart'
    show AndroidPositionSource;
import '../recording/position_source.dart' show PositionSource;
import '../recording/recording_session.dart';
import '../recording/staging_gpx.dart'
    show FileStageSink, GpxStageWriter, renameGpxTrack, salvageGpx;
import '../storage/track_store.dart';
import 'import_coordinator.dart' show ImportCoordinator;
import 'recording_live.dart';

/// The recording concern of the app model: the session lifecycle
/// (start/stop-with-name/pause/resume), staging under `recording/`,
/// startup salvage of killed sessions, the per-fix repaint channel and the
/// battery advisory. Not a Listenable itself: [onChanged] forwards
/// structural notifications to the owning [AppModel]; per-fix ticks go to
/// [recordingLive] only.
class RecordingController {
  RecordingController({
    required this.store,
    required this.imports,
    required this.onChanged,
  });

  final TrackStore store;
  final ImportCoordinator imports;
  final void Function() onChanged;

  /// The live recording session, or null. The map's HUD chip reads this.
  RecordingSession? _recording;
  RecordingSession? get recording => _recording;

  /// The file the live session stages its fixes into, or null.
  File? _recordingFile;
  bool get isRecording => _recording != null;

  /// The per-fix repaint channel: the session's 1 Hz fixes notify only
  /// this, so the live HUD, marker and trace rebuild without dragging the
  /// whole model tree (fog overlay, toolbar) along.
  final recordingLive = RecordingLiveState();

  /// Repaints the UI for one delivered recording fix: the recording live
  /// subtree rebuilds off the session's intake, whose 1 Hz fixes are the
  /// tick it needs.
  void notifyRecordingFix() => recordingLive.notify();

  /// Starts recording: the while-in-use permission is requested up front
  /// (same flow as the locate attempt — a session is never started from the
  /// background), the engine consumes the Android source, and fixes
  /// stage into `<app root>/recording/<start timestamp>.gpx` as they
  /// arrive. Returns the staged file's name, or null when the
  /// user declined (or no host plugin answers — widget tests run here);
  /// desktop runs never get here, the Record action stays hidden where
  /// the platform has no location support. Spec rule: desktop recording
  /// is backlog, Linux ships no location source at all.
  Future<String?> startRecording(
      {PositionSource? source, bool permissionGate = true}) async {
    if (_recording != null) return null; // One at a time.
    if (permissionGate) {
      try {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return null;
        }
      } catch (_) {
        // No host plugin (widget tests, a broken setup): the gate fails
        // closed instead of half-starting a session nobody can feed.
        return null;
      }
    }
    final start = DateTime.now();
    final recordingDir = Directory(
        '${store.root.path}${Platform.pathSeparator}recording');
    recordingDir.createSync(recursive: true);
    final file = File(
        '${recordingDir.path}${Platform.pathSeparator}'
        '${start.millisecondsSinceEpoch}.gpx');
    final sink = FileStageSink(file);
    final session = RecordingSession(
      stage: GpxStageWriter(sink, name: recordingName(start)),
      // The dashboard's tick: every delivered fix, after the engine
      // processed it, repaints the HUD and moves the follow-camera.
      onFix: (_) => notifyRecordingFix(),
    );
    _recording = session;
    _recordingFile = file;
    session.start(source ?? const AndroidPositionSource());
    onChanged();
    return file.uri.pathSegments.last;
  }

  /// Stops recording: the finalized GPX goes through the unified import
  /// pipeline like any other source (dedup, fog, road corridors all
  /// behave identically for a recorded track), and the staged file is
  /// deleted — the catalog owns the copy under `tracks/`. A killed
  /// process never gets here: its un-finalized file stays behind, and
  /// the startup salvage imports the partial track.
  ///
  /// [name], when supplied (the stop-with-name dialog), becomes the
  /// track's GPX `<name>` — and so the catalog name — in place of the
  /// staged header's start timestamp; it is written into the finalized
  /// bytes before the import, so dedup, fog and road matching all see
  /// the final bytes.
  Future<void> stopRecording({String? name}) async {
    final session = _recording;
    final file = _recordingFile;
    if (session == null || file == null) return;
    _recording = null;
    _recordingFile = null;
    onChanged(); // The chip is gone while the import still runs.
    await session.stop();
    final bytes = await file.readAsBytes();
    if (bytes.isNotEmpty) {
      var gpx = utf8.decode(bytes);
      if (name != null && name != session.stage.trackName) {
        gpx = renameGpxTrack(gpx, name);
      }
      imports.importRecordingBytes(
          utf8.encode(gpx), (name ?? session.stage.trackName));
    }
    // The staged file is spent; the catalog's copy is the one that stays.
    if (file.existsSync()) file.deleteSync();
  }

  /// Pauses the live session: the current `<trkseg>` closes, the paused
  /// stretch changes neither distance nor moving time, and the resume —
  /// the next accepted fix — opens a new segment. No-op when no session
  /// runs or none is paused.
  void pauseRecording() {
    final session = _recording;
    if (session == null) return;
    session.pause();
    onChanged();
  }

  /// Resumes a paused session (see [pauseRecording]): the next accepted
  /// fix opens a new `<trkseg>`. No-op when no session runs or none is
  /// paused.
  void resumeRecording() {
    final session = _recording;
    if (session == null || session.state != RecordingState.paused) return;
    session.resume();
    onChanged();
  }

  /// Un-finalized (or un-imported) recordings found and imported at
  /// startup — the staged files of killed sessions. The UI announces
  /// these once; the names are the catalog names the GPX carries, so
  /// sentence-building stays with the strings.
  final List<String> salvagedRecordingNames = [];

  /// Imports every staged recording left over under `recording/`: a
  /// kill between finalize and the catalog import leaves a complete
  /// file, which imports as-is; a kill mid-session leaves one missing
  /// the closers, which salvage repairs first; a kill before the first
  /// flushed point leaves nothing usable, which is junk and is removed.
  /// Unreadable files stay put — unknown bytes are not destroyed on a
  /// guess, they surface again next start.
  Future<void> salvageRecordings() async {
    final dir = Directory(
        '${store.root.path}${Platform.pathSeparator}recording');
    if (!dir.existsSync()) return;
    for (final entry in dir.listSync()) {
      if (entry is! File || !entry.path.endsWith('.gpx')) continue;
      String text;
      try {
        text = await entry.readAsString();
      } on Exception {
        continue; // unreadable: leave it for a later run
      }
      final gpx = text.contains('</gpx>') ? text : salvageGpx(text);
      if (gpx == null) {
        // Nothing was ever staged (header only): junk, removed.
        entry.deleteSync();
        continue;
      }
      final result = imports.importRecordingBytes(
          utf8.encode(gpx), entry.uri.pathSegments.last);
      entry.deleteSync();
      if (result.imported) {
        salvagedRecordingNames.add(result.track!.name);
        onChanged();
      }
    }
  }

  /// Whether Android's battery manager exempts the app — the risk the
  /// recording robustness note in Settings is about (OEM battery managers
  /// kill foreground services regardless of the OS's own). Null when the
  /// platform cannot say (no host plugin; desktop runs, tests).
  Future<bool?> batteryOptimizationExcluded() async {
    try {
      return await hostChannel
          .invokeMethod<bool>('batteryOptimizationExcluded');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The soft POST_NOTIFICATIONS ask (API 33+): one non-blocking dialog,
  /// fired from the Record tap, whose grant result decides only whether
  /// the recording foreground service's notification is shown — a
  /// refusal leaves the session mute, never stopped. Null when the
  /// platform cannot say (no host plugin; desktop runs, tests).
  Future<bool?> requestPostNotifications() async {
    try {
      return await hostChannel.invokeMethod<bool>('requestPostNotifications');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens Android's battery-optimization settings screen: the advisory's
  /// soft tap-through. Never an automated exemption request (the intent
  /// Play flags; see the recording research report).
  Future<void> openBatteryOptimizationSettings() async {
    try {
      await hostChannel.invokeMethod('openBatteryOptimizationSettings');
    } on MissingPluginException {
      // No host plugin: nothing to open.
    } on PlatformException {
      // The settings screen is unavailable: nothing to open.
    }
  }

  /// A staged track's name inside the GPX, and the stop dialog's text
  /// default: the current time's numerals (`recordingName(DateTime.now())`
  /// at stop, the start at staging), so a recorded track reads by when it
  /// was taken (locale-independent — model classes never build sentences).
  String recordingName(DateTime start) =>
      '${start.year.toString().padLeft(4, '0')}-'
      '${start.month.toString().padLeft(2, '0')}-'
      '${start.day.toString().padLeft(2, '0')} '
      '${start.hour.toString().padLeft(2, '0')}:'
      '${start.minute.toString().padLeft(2, '0')}';
}
