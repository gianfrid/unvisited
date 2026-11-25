import 'dart:convert';


import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/storage/track_store.dart';

import 'helpers.dart';

/// JPEG SOI + a blob, so the store's content sniff picks `.jpg`.
List<int> jpegBytes([int seed = 0]) =>
    [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(32, seed)];

/// PNG magic + a blob, so the same sniff picks `.png`.
final pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(32, 7)];

void main() {
  group('photo storage', () {
    test('stores a photo under photos/ and catalogs its capture data',
        () async {
      final store = TrackStore(createRoot());
      await store.load();
      final when = DateTime.utc(2026, 11, 24, 10, 30);

      final photo = store.addPhoto(jpegBytes(1),
          lat: 45.1, lon: 9.2, takenAt: when);

      expect(store.photos, hasLength(1));
      expect(photo.id, contentHash(jpegBytes(1)));
      expect(photo.file, '${photo.id}.jpg');
      expect(photo.lat, 45.1);
      expect(photo.lon, 9.2);
      expect(photo.takenAt, when);
      final file = store.photoFileFor(photo);
      expect(file.existsSync(), isTrue,
          reason: 'the app owns a copy under photos/');
      expect(file.readAsBytesSync(), jpegBytes(1));
    });

    test('a PNG sniffs its real extension', () async {
      final store = TrackStore(createRoot());
      await store.load();
      final photo = store.addPhoto(pngBytes,
          lat: 1, lon: 2, takenAt: DateTime.utc(2026, 1, 1));
      expect(photo.file.endsWith('.png'), isTrue);
    });

    test('byte-identical photos dedup; the stored entry is the record',
        () async {
      final store = TrackStore(createRoot());
      await store.load();
      final bytes = jpegBytes(2);
      final first = store.addPhoto(bytes,
          lat: 45.1, lon: 9.2, takenAt: DateTime.utc(2026, 11, 24));
      final second = store.addPhoto(bytes,
          lat: 46.0, lon: 10.0, takenAt: DateTime.utc(2026, 11, 25));

      expect(identical(second, first), isTrue,
          reason: 'the original capture position and time stay');
      expect(store.photos, hasLength(1));
      expect(second.lat, 45.1);
    });

    test('the position edit persists across a reload', () async {
      final root = createRoot();
      final store = TrackStore(root);
      await store.load();
      final photo = store.addPhoto(jpegBytes(3),
          lat: 45.1, lon: 9.2, takenAt: DateTime.utc(2026, 11, 24));

      await store.updatePhotoPosition(photo, lat: 45.2, lon: 9.3);

      final reopened = TrackStore(root);
      await reopened.load();
      expect(reopened.photos, hasLength(1));
      expect(reopened.photos.single.lat, 45.2);
      expect(reopened.photos.single.lon, 9.3);
    });

    test('removePhoto deletes the entry and the file', () async {
      final store = TrackStore(createRoot());
      await store.load();
      final photo = store.addPhoto(jpegBytes(4),
          lat: 1, lon: 2, takenAt: DateTime.utc(2026, 11, 24));
      final file = store.photoFileFor(photo);

      await store.removePhoto(photo);

      expect(store.photos, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test('load skips a photo whose file is gone, keeps the rest',
        () async {
      final root = createRoot();
      final store = TrackStore(root);
      await store.load();
      final kept = store.addPhoto(jpegBytes(5),
          lat: 1, lon: 2, takenAt: DateTime.utc(2026, 11, 24));
      final gone = store.addPhoto(jpegBytes(6),
          lat: 3, lon: 4, takenAt: DateTime.utc(2026, 11, 24));
      store.photoFileFor(gone).deleteSync();

      final reopened = TrackStore(root);
      await reopened.load();
      expect(reopened.photos.map((p) => p.id), [kept.id]);
    });

    test('load tolerates malformed photo entries', () async {
      final root = createRoot();
      final store = TrackStore(root);
      await store.load();
      final photo = store.addPhoto(jpegBytes(7),
          lat: 1, lon: 2, takenAt: DateTime.utc(2026, 11, 24));
      // Hand-edit the index like a corrupted write: a broken entry next
      // to a good one must never lose the good one.
      final map =
          jsonDecode(store.indexFile.readAsStringSync()) as Map<String, dynamic>;
      map['photos'] = [
        {'id': 'no-file-no-fields'},
        'not even a map',
        photo.toMap(),
      ];
      store.indexFile.writeAsStringSync(jsonEncode(map));

      final reopened = TrackStore(root);
      await reopened.load();
      expect(reopened.photos.map((p) => p.id), [photo.id]);
    });

    test('the photos setting persists (default on)', () async {
      final root = createRoot();
      final store = TrackStore(root);
      await store.load();
      expect(store.photosEnabled, isTrue);

      await store.savePhotosEnabled(false);
      final reopened = TrackStore(root);
      await reopened.load();
      expect(reopened.photosEnabled, isFalse);
      // The toggle never touches stored photos.
      expect(reopened.photos, isEmpty);
    });

    test('clearAll wipes photos and their files', () async {
      final root = createRoot();
      final store = TrackStore(root);
      await store.load();
      final photo = store.addPhoto(jpegBytes(8),
          lat: 1, lon: 2, takenAt: DateTime.utc(2026, 11, 24));

      await store.clearAll();

      expect(store.photos, isEmpty);
      expect(store.photoFileFor(photo).existsSync(), isFalse);
      final reopened = TrackStore(root);
      await reopened.load();
      expect(reopened.photos, isEmpty);
    });
  });
}
