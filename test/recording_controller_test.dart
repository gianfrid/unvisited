import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/recording/position_source.dart' show PositionFix;
import 'package:unvisited/recording/recording_session.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/import_coordinator.dart';
import 'package:unvisited/ui/recording_controller.dart';

import 'helpers.dart';

// These tests run the real controller over a real store root: the
// permission gate is bypassed (permissionGate: false — it is the host
// channel's concern) and a FakePositionSource feeds synthetic fixes. The
// stop path reads the staged file through real file IO, so no FakeAsync.
void main() {
  late TrackStore store;
  late ImportCoordinator imports;
  late RecordingController controller;
  late int changes;

  setUp(() {
    final root = createRoot();
    store = TrackStore(root);
    changes = 0;
    imports = ImportCoordinator(
      store: store,
      roadMatcher: () => null,
      onChanged: () => changes++,
    );
    controller = RecordingController(
      store: store,
      imports: imports,
      onChanged: () => changes++,
    );
  });

  Directory stagedDir() =>
      Directory('${store.root.path}${Platform.pathSeparator}recording');

  PositionFix fix(int second, {double lat = 52.5200}) => PositionFix(
    lat: lat,
    lon: 13.4050,
    // Distinct minutes keep the engine's staleness logic happy.
    time: DateTime.utc(2026, 1, 1, 10, second),
    accuracy: 5,
  );

  /// Starts a session on the given source and delivers the fixes.
  Future<FakePositionSource> feed(List<PositionFix> fixes) async {
    final source = FakePositionSource();
    await controller.startRecording(source: source, permissionGate: false);
    for (final f in fixes) {
      source.controller.add(f);
    }
    await pumpEventQueue();
    return source;
  }

  group('start', () {
    test('stages a file under recording/ and reports its name', () async {
      final name = await controller.startRecording(
        source: FakePositionSource(),
        permissionGate: false,
      );

      expect(name, matches(RegExp(r'^\d+\.gpx$')));
      expect(controller.isRecording, isTrue);
      expect(controller.recording, isNotNull);
      expect(stagedDir().listSync(), hasLength(1));
      expect(changes, greaterThan(0));
    });

    test('a second start is refused while one session runs', () async {
      await controller.startRecording(
        source: FakePositionSource(),
        permissionGate: false,
      );
      final second = await controller.startRecording(permissionGate: false);

      expect(second, isNull);
      expect(stagedDir().listSync(), hasLength(1));
    });
  });

  group('live fixes', () {
    test('each delivered fix ticks the per-fix repaint channel', () async {
      var liveTicks = 0;
      controller.recordingLive.addListener(() => liveTicks++);

      await feed([fix(0), fix(1, lat: 52.5201)]);

      expect(liveTicks, 2);
      final session = controller.recording!;
      expect(session.pointCount, 2);
      expect(session.distanceMeters, greaterThan(0));
    });

    test('pause closes the segment; resume opens it again', () async {
      final source = FakePositionSource();
      await controller.startRecording(source: source, permissionGate: false);
      source.controller.add(fix(0));
      await pumpEventQueue();

      controller.pauseRecording();
      expect(controller.recording!.state, RecordingState.paused);
      expect(controller.recording!.liveSegments, hasLength(1));

      // A fix during a pause records nothing.
      source.controller.add(fix(2, lat: 52.5201));
      await pumpEventQueue();
      expect(controller.recording!.pointCount, 1);

      controller.resumeRecording();
      expect(controller.recording!.state, RecordingState.recording);

      // The next accepted fix opens a new segment.
      source.controller.add(fix(5, lat: 52.5202));
      await pumpEventQueue();

      final session = controller.recording!;
      expect(session.pointCount, 2);
      expect(session.liveSegments, hasLength(2));
    });
  });

  group('stop', () {
    test(
      'finalizes through the unified pipeline under the given name',
      () async {
        await feed([fix(0), fix(1, lat: 52.5201)]);

        await controller.stopRecording(name: 'Evening ride');

        expect(controller.isRecording, isFalse);
        expect(store.tracks.single.name, 'Evening ride');
        expect(store.tracks.single.pointCount, 2);
        // The staged copy is spent; the catalog owns the track now.
        expect(
          stagedDir().existsSync() ? stagedDir().listSync() : const [],
          isEmpty,
        );
      },
    );

    test(
      'without a name the staged header name becomes the track name',
      () async {
        await feed([fix(0), fix(1, lat: 52.5201)]);
        final headerName = controller.recording!.stage.trackName;

        await controller.stopRecording();

        expect(headerName, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
        expect(store.tracks.single.name, headerName);
      },
    );

    test('stop with no session running is a no-op', () async {
      await controller.stopRecording();
      expect(store.tracks, isEmpty);
    });
  });

  group('discard', () {
    test('deletes the staged file; nothing enters the catalog', () async {
      await feed([fix(0)]);

      await controller.discardRecording();

      expect(controller.isRecording, isFalse);
      expect(store.tracks, isEmpty);
      expect(
        stagedDir().existsSync() ? stagedDir().listSync() : const [],
        isEmpty,
      );
    });
  });

  group('startup salvage', () {
    test('a complete leftover file imports under the GPX name', () async {
      const gpx =
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
          '<trk><name>Salvaged</name><trkseg>'
          '<trkpt lat="52.5200" lon="13.4050">'
          '<time>2026-01-01T10:00:00Z</time></trkpt>'
          '</trkseg></trk></gpx>';
      stagedDir().createSync(recursive: true);
      File('${stagedDir().path}${Platform.pathSeparator}1234.gpx')
          .writeAsStringSync(gpx);

      await controller.salvageRecordings();

      expect(controller.salvagedRecordingNames, ['Salvaged']);
      expect(store.tracks.single.name, 'Salvaged');
      expect(stagedDir().listSync(), isEmpty);
    });

    test(
      'a header-only leftover (no point ever flushed) is junk, removed',
      () async {
        stagedDir().createSync(recursive: true);
        File('${stagedDir().path}${Platform.pathSeparator}5678.gpx')
            .writeAsStringSync(
              '<?xml version="1.0" encoding="UTF-8"?>\n'
              '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
              '<trk><name>Junk</name></trk>',
            );

        await controller.salvageRecordings();

        expect(controller.salvagedRecordingNames, isEmpty);
        expect(store.tracks, isEmpty);
        expect(stagedDir().listSync(), isEmpty);
      },
    );

    test('an unreadable file stays put for the next run', () async {
      stagedDir().createSync(recursive: true);
      File('${stagedDir().path}${Platform.pathSeparator}broken.gpx')
          .writeAsBytesSync([0xFF, 0xFE, 0x00]); // not UTF-8

      await controller.salvageRecordings();

      expect(controller.salvagedRecordingNames, isEmpty);
      expect(store.tracks, isEmpty);
      expect(
        stagedDir().listSync().where((e) => e.path.endsWith('broken.gpx')),
        hasLength(1),
      );
    });

    test('a recording/ dir that never existed is no salvage at all', () async {
      await controller.salvageRecordings();

      expect(controller.salvagedRecordingNames, isEmpty);
    });
  });
}
