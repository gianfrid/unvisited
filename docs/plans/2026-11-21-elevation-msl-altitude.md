# Elevation datum: report MSL altitude where the platform provides it

Implements: TODO.md #1 (the elevation-offset decision)

## Finding (field data, 2026-11-21 — no precise coordinates recorded here)

A same-ride pair (Garmin Instinct 3 FIT + unvisited GPX) showed the phone
track reading ~47 m above the watch's barometric altitude. EGM96 at the
test region gives a geoid undulation N ≈ +47 m, and Android's
`Location.getAltitude()` is WGS84 ellipsoidal height (h = MSL + N) — so
the offset is exactly the geoid, not watch drift and not a phone bug.
The Garmin FIT carries no per-point elevation, so the watch side is
MSL only in its summaries; imported watch/Strava files are MSL.

## Decision

**Display and store MSL where the platform provides it; document the
raw-ellipsoid caveat otherwise.**

- geolocator_android 5.2.1's `AndroidSettings.useMSLAltitude` computes
  MSL (EGM2008, from NMEA $GPGGA) and reports it as `altitude` on
  Android N+ devices that supply NMEA; where unsupported it silently
  stays WGS84 geoidal height. Enabling it is the only platform lever —
  geolocator exposes a single altitude per fix, so "keep storage raw
  and convert at display time" is not reachable through this plugin.
  Consequence: newly recorded tracks store MSL on supporting devices
  (matching imported tracks — one datum in the catalog going forward);
  already-recorded tracks keep their raw ellipsoidal values.
- The stats panel's "Altitude" row then shows MSL on supported devices,
  raw GPS height on the rest. The row label stays "Altitude"; the caveat
  is documented (README user-facing, ARCHITECTURE design) rather than a
  second label — the datum is a per-device fallback, not a per-track one.
- Elevation gain/loss is datum-invariant at local scale (N varies
  < 0.1 m over a ride), so no climbing stat is affected either way.
- No bundled geoid grid, no new package, no network — SPEC rules hold.

## Steps

1. `android_position_source.dart`: `useMSLAltitude: true` in the
   `AndroidSettings`, with a comment stating the datum contract
   (MSL where the device provides it, WGS84 ellipsoidal otherwise).
2. `position_source.dart`: doc note on `PositionFix.ele` — may be MSL
   or ellipsoidal depending on platform support; stored as-is.
3. README: one sentence in the Recording bullet — altitude is MSL where
   the device supports it, raw GPS (WGS84 ellipsoid) height otherwise;
   imported watch/Strava tracks are MSL.
4. ARCHITECTURE.md: same note in the recording engine paragraph.
5. TODO.md #1 removed with the completing commit (measurement done,
   decision recorded here).
6. No unit-test seam changes (the flag is platform-side; the engine's
   `ele` handling is unchanged); `flutter analyze` + `flutter test`
   must stay green.
