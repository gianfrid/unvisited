import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unvisited/storage/track_store.dart';

import 'helpers.dart';

void main() {
  group('catalog export/import', () {
    test('round-trips the catalog and dedups a re-import', () async {
      final store = TrackStore(createRoot());
      await store.load();
      store.importBytes(fixture('morning_walk.gpx'), filename: 'morning_walk.gpx');
      store.importBytes(fixture('activity_ride.fit'), filename: 'activity_ride.fit');
      expect(store.tracks, hasLength(2));

      final zip = store.exportCatalogBytes();

      final store2 = TrackStore(createRoot());
      await store2.load();
      expect(store2.importCatalogBytes(zip), 2);
      expect(
        store2.tracks.map((t) => t.id),
        unorderedEquals(store.tracks.map((t) => t.id)),
        reason: 'the round-trip restores the same content-hash ids',
      );
      // Re-importing the same export adds nothing (content-hash dedup).
      expect(store2.importCatalogBytes(zip), 0);
    });

    test('rejects a zip that is not an Unvisited export', () async {
      final store = TrackStore(createRoot());
      await store.load();
      final foreign = Archive()
        ..addFile(ArchiveFile('foo.txt', 3, [1, 2, 3]));
      expect(
        () => store.importCatalogBytes(ZipEncoder().encode(foreign)),
        throwsFormatException,
      );
    });
  });
}
