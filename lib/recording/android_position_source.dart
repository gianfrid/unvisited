/// The Android [PositionSource]: geolocator's `getPositionStream` wrapped
/// behind the recording engine's interface (SPEC's portability rule — the
/// session, the dashboard and the tests all read the same contract).
///
/// geolocator's own foreground service carries the session: the promoted
/// stream is user-visible work with the mandatory notification (and an
/// optional wake lock), so no native service of ours exists — matching
/// the Locate feature's shape. Only while-in-use location is ever read.
library;

import 'package:geolocator/geolocator.dart';

import 'position_source.dart';

/// Fixes flowing from geolocator with the Android foreground service's
/// settings: best available accuracy at a 1 s interval, no distance
/// filter (the engine's own filters decide acceptance; the plugin's
/// distance filter would silently drop real fixes the engine must judge),
/// wake lock enabled — screen-off sessions must not lose the fix.
///
/// The notification is mandatory under promotion; Android requires
/// `POST_NOTIFICATIONS` for it and the manifest gains the plugin's
/// required foreground-service entries (see the merged declaration at
/// target API 34+ — verified on-device per SPEC's manual checklist).
class AndroidPositionSource implements PositionSource {
  const AndroidPositionSource();

  @override
  Stream<PositionFix> get stream =>
      Geolocator.getPositionStream(
        // ForegroundNotificationConfig is not const-constructible in
        // geolocator 14; the Android settings one stays const.
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          intervalDuration: const Duration(seconds: 1),
          // MSL (EGM2008, from NMEA) instead of raw WGS84 ellipsoidal
          // height wherever the device provides it (Android N+ with NMEA
          // $GPGGA); elsewhere the plugin falls back to geoidal height.
          // The engine and the stored GPX take the value as-is — the
          // datum note lives in README/ARCHITECTURE (see the 2026-11-21
          // elevation plan).
          useMSLAltitude: true,
          foregroundNotificationConfig: ForegroundNotificationConfig(
            // The notification strings ride with the service's config (in
            // Android's locale, set before Dart lives); OpenTracks keeps
            // the same two.
            notificationTitle: 'unvisited',
            notificationText: 'Recording',
            notificationIcon: AndroidResource(
                name: 'ic_launcher', defType: 'mipmap'),
            enableWakeLock: true,
            setOngoing: true,
          ),
        ),
      ).map(_toFix);

  /// One geolocator fix through the engine's seam; geolocator packs the
  /// same numbers the engine filters on (accuracy/speed/heading in SI).
  static PositionFix _toFix(Position p) => PositionFix(
        lat: p.latitude,
        lon: p.longitude,
        ele: p.altitude.isFinite ? p.altitude : null,
        accuracy: p.accuracy.isFinite && p.accuracy >= 0 ? p.accuracy : null,
        speed: p.speed.isFinite && p.speed >= 0 ? p.speed : null,
        heading: p.heading.isFinite && p.heading >= 0 ? p.heading : null,
        time: p.timestamp.toUtc(),
      );
}
