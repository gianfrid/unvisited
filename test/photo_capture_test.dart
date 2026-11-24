import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:unvisited/photos/photo_source.dart';
import 'package:unvisited/storage/track_store.dart';
import 'package:unvisited/ui/app_model.dart';

import 'helpers.dart';

void main() {
  late FakePhotoSource source;
  late AppModel model;
  late TrackStore store;

  setUp(() async {
    source = FakePhotoSource(const PhotoCaptureDeclined());
    store = TrackStore(createRoot());
    await store.load();
    model = AppModel(store, photoSource: source);
    await model.load();
  });

  group('takePhoto', () {
    test('saves the captured bytes at the given position', () async {
    source.outcome = PhotoCaptureSucceeded(jpegBytes());
      final when = DateTime.utc(2026, 11, 24, 9, 15);
      var notified = 0;
      model.addListener(() => notified++);

      final result = await model.takePhoto(
        const LatLng(45.4642, 9.19),
        takenAt: when,
      );

      expect(result, isA<PhotoAdded>());
      final photo = (result as PhotoAdded).photo;
      expect(photo.lat, 45.4642);
      expect(photo.lon, 9.19);
      expect(photo.takenAt, when);
      expect(model.photos, hasLength(1));
      expect(store.photoFileFor(photo).readAsBytesSync(), jpegBytes());
      expect(notified, 1,
          reason: 'the new pin mounts off one catalog notification');
      expect(source.captures, 1);
    });

    test('a declined capture changes nothing and does not notify', () async {
      var notified = 0;
      model.addListener(() => notified++);

      final result = await model.takePhoto(const LatLng(1, 2));

      expect(result, isA<PhotoAddDeclined>());
      expect(model.photos, isEmpty);
      expect(notified, 0);
    });

    test('a failed capture changes nothing and does not notify', () async {
      source.outcome = const PhotoCaptureFailed('boom');
      var notified = 0;
      model.addListener(() => notified++);

      final result = await model.takePhoto(const LatLng(1, 2));

      expect(result, isA<PhotoAddFailed>());
      expect(model.photos, isEmpty);
      expect(notified, 0);
    });

    test('a repeated identical capture keeps the stored entry', () async {
      source.outcome = PhotoCaptureSucceeded(jpegBytes(9));
      final first = await model.takePhoto(const LatLng(1, 2));

      final second = await model.takePhoto(const LatLng(3, 4));

      expect(model.photos, hasLength(1));
      expect(
        (second as PhotoAdded).photo.id,
        (first as PhotoAdded).photo.id,
      );
      expect(second.photo.lat, 1,
          reason: 'the stored capture is the record');
    });
  });

  group('photo editing', () {
    late StoredPhoto photo;

    setUp(() async {
      source.outcome = PhotoCaptureSucceeded(jpegBytes(5));
      final result = await model.takePhoto(const LatLng(45.0, 9.0));
      photo = (result as PhotoAdded).photo;
    });

    test('repositionPhoto moves and persists the pin', () async {
      await model.repositionPhoto(photo, const LatLng(45.5, 9.5));

      expect(model.photos.single.lat, 45.5);
      final reopened = AppModel(TrackStore(store.root), photoSource: source);
      await reopened.load();
      expect(reopened.photos.single.lat, 45.5);
    });

    test('deletePhoto removes the entry and its file', () async {
      await model.deletePhoto(photo);

      expect(model.photos, isEmpty);
      expect(store.photoFileFor(photo).existsSync(), isFalse);
    });
  });
}
