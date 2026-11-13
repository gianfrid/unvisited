# Active Recording and Ride/Walk Dashboard for Unvisited — Research Report

**Question.** How should Unvisited — today a local-only import-and-view app — add **active GPS recording** (Android first) and turn the map into a **usable dashboard for bike riding and walking**: live position, speed/distance/duration readouts, a follow-camera, and as close to an OsmAnd/Google-Navigation-style **tilted "3D" map** as the architecture allows? What does Android require of a recording session, which intake/filters/stats are right, and which tilt route fits flutter_map + raster OSM tiles?

**Date of research:** 2026-11-13. Versions, PR states and policy pages current as of this date.

**Decision context.** The owner decided: the app moves beyond the viewer stage — in-app recording is in scope (Android), the view-only framing is retired from the docs; desktop Linux recording stays in the backlog (geolocator has no Linux implementation); the end state is a dashboard-style map, tilt "nice to have", as close to Google Maps navigation as practical.

## Executive summary

1. **Recording needs zero new packages.** `geolocator` (already a dependency, ^14.0.1) provides a continuous `getPositionStream` on Android with its own **foreground service**: `AndroidSettings(foregroundNotificationConfig: …)` promotes the stream to a visible, battery-priority session with an optional partial wake lock. What is missing is (a) manifest permissions, (b) session logic (start/pause/stop, filtering, stats, staged file). ([geolocator](https://pub.dev/packages/geolocator), [ForegroundNotificationConfig API](https://pub.dev/documentation/geolocator/latest/geolocator/ForegroundNotificationConfig-class.html))
2. **The Android 14+ foreground-service matrix is small but strict.** A location-type FGS needs the `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION` manifest permissions and the type declared on the service; because a recording session *starts from a Record button* (app in use), while-in-use fine location suffices — **`ACCESS_BACKGROUND_LOCATION` is not needed and should stay out** (starting a location FGS from the background is what demands it). Google Play additionally requires a Play Console declaration for location-type FGS use. ([FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types), [FGS types required (14)](https://developer.android.com/about/versions/14/changes/fgs-types-required), [Play policy](https://support.google.com/googleplay/android-developer/answer/13392821))
3. **Design for process death.** geolocator's own docs warn the FGS raises priority but does not *guarantee* the process survives; OEM battery managers (LG/Motorola/Samsung…) kill recording services and every long-standing recorder app documents battery-optimization exemptions. Consequence: append every accepted fix to a staging GPX (`trkseg` breaks encode pauses/fix-loss), flush on a short cadence, **finalize by feeding the file through the app's own unified import pipeline** (content-hash dedup and road-corridor unlocking come for free), and salvage an un-finalized file at next start. ([geolocator docs](https://pub.dev/documentation/geolocator_android/latest/), [OpenTracks battery guide](https://opentracks.app/en/article/improve-your-gps-geolocation-in-3-lessons), [GPSLogger FAQ](https://gpslogger.app/))
4. **Intake: 1 s best-accuracy, filtered.** Android's own battery guidance is the accuracy/frequency/latency triad; a 1 s `intervalDuration` with best accuracy is the Strava/OpenTracks-class default for ride/walk recording and costs a few percent per couple of hours on mid-range hardware per practitioner reports. Drop fixes with reported accuracy worse than ~50 m and stale fixes (`maxUpdateAge`); take speed from the fused provider (`Position.speed`/`speedAccuracy`) with a haversine-delta fallback. ([location battery](https://developer.android.com/develop/sensors-and-location/location/battery), [geolocator Position](https://pub.dev/documentation/geolocator_platform_interface/latest/geolocator_platform_interface/Position-class.html), [battery reports](https://stackoverflow.com/questions/44654818/how-much-battery-does-gps-consume))
5. **Tilt: do not change rendering stacks.** flutter_map itself is adding pitch: collaborator greensopinion's PR stack (#[2283] `MapOptions.maxPitch` up to 60° with ground layers drawn in perspective + #[2282] pitch gestures, on a `pitch-support` base branch created by the maintainer on 2026-10-25; pitched camera fits, pitched-map tile LOD and horizon limits queued behind it) delivers exactly OsmAnd-style tilt over raster tiles — and Unvisited's fog circles and road corridors are *ground layers*, so they get perspective without any new code path. Plan course-up + follow-mode now, adopt pitch as a release bump when it ships. ([PR #2283](https://github.com/fleaflet/flutter_map/pull/2283), [PR #2282](https://github.com/fleaflet/flutter_map/pull/2282), [issue #1268](https://github.com/fleaflet/flutter_map/issues/1268))
6. **Alternatives were scored and rejected for now.** `maplibre_gl` has pitch/bearing today but is a platform-view rendering swap that orphans the fog-of-war circle layer work (kept as fallback if upstream pitch stalls); `mapigrade` (MapLibre-Native-as-Texture base layer *inside* flutter_map) is exactly the right idea but explicitly an experimental proof of concept (v0.0.4, Oct–Nov 2026); whole-widget Matrix4 perspective hacks break gestures and hit-testing. ([maplibre_gl](https://pub.dev/packages/maplibre_gl), [mapigrade](https://github.com/greensopinion/mapigrade))
7. **True 3D buildings are a separate, bigger decision.** OsmAnd renders 3D buildings only through its *vector* engine (its raster maps tilt, its buildings do not extrude); the Google-Maps look would require vector tile sources plus terrain/building styles — new data sources beyond the current raster-OSM-only network rule. Explicitly deferred as a future owner decision, not part of this plan. ([OsmAnd topography](https://osmand.net/docs/user/plugins/topography/), [OsmAnd raster maps](https://osmand.net/docs/user/map/raster-maps/))
8. **The end-state "dashboard" is one screen away, not a new app.** A Record action + recording HUD chip + a stats panel (speed/distance/duration/moving-average) + follow-camera with course-up marker compose with everything that already exists: the recorded GPX lands in the same catalog, unlocks the same fog, and matches the same road corridors as any import.

## Methodology

Search angles: the Android foreground-service and location-permission documentation (types, Play policy, while-in-use semantics), geolocator's pub.dev docs and API references (AndroidSettings, ForegroundNotificationConfig, Position), open-source recorder precedents (OpenTracks, GPSLogger) for OEM battery-manager guidance and interval practice, flutter_map's GitHub (pitch issue #1268, the greensopinion PR stack) and MapLibre ecosystem (flutter-maplibre-gl, mapigrade) for tilt feasibility, OsmAnd user documentation for the target UX (tilt on raster, 3D buildings via vector), and GPX 1.1 schema documentation for on-disk format. Package and PR states were read from pub.dev and GitHub on 2026-11-13. Limitation: PR #2283's eventual merge date and API shape are not yet fixed — the tilt slice must re-verify the API against the released changelog before implementation; battery-drain percentages are practitioner reports, not lab measurements.

## Findings

### 1. The recorder already has a home: geolocator's foreground service

geolocator (in pubspec as ^14.0.1; 14.1.0 current) wraps Android's FusedLocationProvider (or the legacy LocationManager) and, since long, ships an Android **foreground service** of its own that a position stream can opt into:

```dart
final stream = Geolocator.getPositionStream(
  locationSettings: AndroidSettings(
    accuracy: LocationAccuracy.best,
    intervalDuration: const Duration(seconds: 1),
    maxUpdateAge: const Duration(seconds: 2),
    foregroundNotificationConfig: ForegroundNotificationConfig(
      notificationTitle: …, notificationMessage: …,
      notificationIcon: …, enableWakeLock: true,
    ),
  ),
);
```

`ForegroundNotificationConfig` carries the notification title/text/icon, a wake-lock toggle, ongoing-notification and channel settings; `AndroidSettings` carries accuracy, distance filter, interval and max-age knobs. The promotion makes Android treat the process as user-visible work with location priority, survives the activity being backgrounded, and posts the notification Android requires. The plugin's own caveat: the FGS "increases the priority of the location work, but it is not a guarantee that Android will keep the application process alive" — the session logic must tolerate death at any flush boundary. ([geolocator](https://pub.dev/packages/geolocator), [AndroidSettings API](https://pub.dev/documentation/geolocator_android/latest/geolocator_android/AndroidSettings-class.html), [ForegroundNotificationConfig API](https://pub.dev/documentation/geolocator_android/latest/geolocator_android/ForegroundNotificationConfig-class.html), [geolocator_android docs](https://pub.dev/documentation/ym_geolocator_android/latest/))

### 2. The Android permission matrix (what slice 2 actually adds)

| Requirement | Where | Status / action |
|---|---|---|
| `ACCESS_FINE_LOCATION` (+coarse) | manifest + runtime prompt | Already declared; already prompted by the Locate action. Recording re-checks before start. |
| `FOREGROUND_SERVICE` | manifest (normal permission) | Add — required to run any FGS. |
| `FOREGROUND_SERVICE_LOCATION` (API 34+) | manifest (normal permission) | Add — required for a location-type FGS when targeting API 34+. |
| FGS type `location` on the service | service declaration | geolocator_android's own merged manifest declares its foreground service; verify `foregroundServiceType` at the target SDK during slice 2 (merged-manifest inspection, `aapt`/play console pre-launch report). |
| `POST_NOTIFICATIONS` (API 33+) | manifest + soft runtime request | Add; if denied, the FGS still records but stays mute — ask softly, never block recording on it. |
| `ACCESS_BACKGROUND_LOCATION` | — | **Not used, deliberately.** Android docs: a location-type FGS may start while the app is in use with while-in-use access; it cannot be *started from the background* without the background grant. Unvisited's session always starts foreground (Record button) and forbids background *start*, which keeps the Play-review footprint small. |
| Play Console FGS declaration | Play policy | Declare location-type FGS use + a demonstration video at first release with recording. |

([FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types), [FGS types required](https://developer.android.com/about/versions/14/changes/fgs-types-required), [FGS launch checks](https://developer.android.com/develop/background-work/services/fgs/launch), [Play FGS policy](https://support.google.com/googleplay/android-developer/answer/13392821), [location permissions](https://developer.android.com/develop/sensors-and-location/location/permissions))

The one hard rule that shapes the UX: **battery managers, not permissions, are the real adversary**. OpenTracks ships per-OEM instructions ("Settings → Battery → Ignore optimizations"), and GPSLogger's FAQ documents task-killer carnage. Unvisited should show a one-tap battery-optimization exemption advisory (deep link `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` only after recording is stopped, or a Settings link — avoid the aggressive intent used by adware that Play flags). ([OpenTracks guide](https://opentracks.app/en/article/improve-your-gps-geolocation-in-3-lessons), [GPSLogger](https://gpslogger.app/))

### 3. Session design: staged GPX through the *existing* pipeline

- **Staging file**: `<app root>/recording/<start timestamp>.gpx`, written incrementally (append points, periodically flush + fsync, recommended 1–5 s cadence — bounded loss window on death).
- **Format**: GPX 1.1 track/segment/point with `<ele>` (schema-enforced order: ele before time). `<trkseg>` breaks carry the semantics "recording paused or fix lost" — a new segment resumes without cutting the track, the exact convention GPX consumers expect. GPX is chosen over FIT because a pure-Dart FIT *writer* would be new code with zero reuse; the GPX parser trivially re-imports what the writer produced (a closed loop: writer fixtures feed the reader's tests). ([GPX 1.1 schema](https://www.topografix.com/GPX/1/1/), [trkseg semantics](https://file-extensions.com/docs/gpx))
- **Stop = import**: the finalized file goes through `store.importBytes` like any share-intent file — content-hash dedup, catalog entry, and road-corridor matching against the active region all behave identically for recorded and imported tracks. No parallel storage path exists.
- **Death ≠ data loss**: a leftover un-finalized staging file at startup imports as a partial track with a notice, rather than being silently dropped; v1 does not attempt to *resume* a killed session (a resumable FGS restart is a heavier, later slice).
- **Testing**: the session state machine (accept/reject filters, segmenting, distance/duration/moving-time, pause/resume, GPX bytes emitted) is pure Dart fed synthetic position streams — the same fixture-driven pattern as the parsers; the geolocator stream itself is wrapped behind a `PositionSource` interface so widget tests and desktop runs share the code path with Android. (SPEC's portability rule applies unchanged.)

### 4. Intake, stats, and battery — the numbers in the docs

Android's location-battery guidance reduces to three dials: **accuracy** (GPS+Wi-Fi+cells, more inputs → more drain), **frequency** (shorter interval → more drain; "the interval shouldn't be too small"), **latency** (immediate delivery vs batching). For ride/walk recording the Strava/OpenTracks-class choice is 1 s high/best accuracy: practitioner measurements put a 2 h riding session at a few percent of a modern phone battery, and the fused provider's `Position.speed`/`speedAccuracy` fields mean the dashboard's speed readout usually does not even need delta math (compute haversine-delta speed as fallback when `speedAccuracy` is poor). Filters: reject fixes with reported accuracy worse than ~50 m (parking-lot noise, tunnels), reject stale fixes via `maxUpdateAge`, and keep the *raw* series unfiltered in the GPX only for accepted points — the fog-of-war overlay's 12 m cell coalescing already absorbs GPS jitter, so recorded points need no smoothing. ([battery](https://developer.android.com/develop/sensors-and-location/location/battery), [optimize](https://developer.android.com/develop/sensors-and-location/location/battery/optimize), [Position API](https://pub.dev/documentation/geolocator_platform_interface/latest/geolocator_platform_interface/Position-class.html), [drain reports](https://stackoverflow.com/questions/44654818/how-much-battery-does-gps-consume))

### 5. Tilt: what exists, what is coming, what to reject

| Strategy | What it is | Spec fit | Effort | Risk | Verdict |
|---|---|---|---|---|---|
| **A. flutter_map pitch (upstream)** | `MapOptions.maxPitch` ≤ 60°, `MapController.pitch`, ground layers in perspective, billboard markers; PR stack by a flutter_map collaborator on the maintainer's `pitch-support` branch (2026-10-25), with pitch gestures, pitched camera fits, pitched-map tile LOD and horizon limits queued | Perfect — no new deps; raster tiles stay; fog circles/corridors are ground layers and tilt with the map | Small once released (param + gesture defaults) | Release timing outside our control | **Recommended target** |
| B. `maplibre_gl` swap | MapLibre GL native maps (platform views): camera pitch/bearing today, vector and raster sources, PMTiles, offline | Weak — new heavyweight dependency (SPEC asks before adding), platform view vs Flutter compositor, re-implements tile cache/attribution/fog layers | Very large (orphan fog_of_war, tile_source, corridor rendering) | Long migration; tile cache policy rework | Rejected; keep as fallback |
| C. `mapigrade` hybrid | MapLibre Native rendered into a Flutter Texture as flutter_map's *base layer* ("MapLibre inside flutter_map") | Attractive idea; explicitly labeled a proof of concept (v0.0.4, Oct–Nov 2026, minSdk 24 by one author) | Medium, but building on a PoC | Project-fork risk high | Watchlist only |
| D. Widget Matrix4 perspective | Wrap `FlutterMap` in a `Transform` with a perspective matrix | No deps | Tiny | Gestures/hit-testing break; tiles skew, no tile LOD | Rejected outright |

OsmAnd — the user's reference — confirms the raster-first reading: its OpenGL renderer tilts plain raster tiles (with horizon fog to keep far-tile cost sane: "the display of remote objects… requires significant computing resources"), while its 3D *buildings* come only from the vector engine (and 3D relief is a plugin/Pro feature). So "OsmAnd-style" = tilted raster + camera that follows course; "Google-Maps-style 3D city" = vector + terrain, a different project. The plan gets the first honestly and defers the second. ([OsmAnd interact-with-map](https://builder.osmand.net/docs/user/map/interact-with-map/), [OsmAnd topography](https://osmand.net/docs/user/plugins/topography/))

What can ship immediately regardless of A's timing: **follow-mode** (camera re-centers on each fix during recording) and a **course-up rotating position marker** (heading from `Position.heading` or the segment bearing) — both trivial with the existing `MapController`, and both compose unchanged under pitched rendering later.

### 6. The dashboard composition (all pieces already exist or are in the plan)

Recording UI = toolbar Record action (state machine: idle → requesting permission → recording ⇄ paused → stopping), a HUD chip showing duration + distance while recording, and an expandable stats panel: current speed (km/h), distance (km), elapsed time, moving time, average moving speed (altitude on equipped devices). Post-stop, the track is just a catalog track: it renders in the fog overlay, unlocks corridors against the active region, and appears in the drawer like any import. Strings go through `app_strings.dart` (en + it) with parameterized counts/durations; model classes never build sentences (existing convention).

## Comparison of recording approaches (why this design)

| Criterion | A. geolocator FGS + staged GPX through own pipeline | B. Native Kotlin FGS service + EventChannel | C. flutter_background_service + geolocator |
|---|---|---|---|
| New packages | **0** | 0 (but a native codebase to maintain) | +1 dependency |
| Restart-after-kill | Partial (salvage import) | Best (service restarts independently) | Partial |
| Code surface | **Small** — stream → session → GPX → existing pipeline | Separated Kotlin/Java service, manifest juggling, channels | Medium |
| Testability | **High** (synthetic streams into the session) | Needs instrumentation | Medium |
| Fit with app's conventions | **Perfect** (single import pipeline, JSON index, local-only) | Duplicates plumbing | Acceptable |

Recommendation: **A**, with the process-death reality handled by flush cadence + salvage rather than by a resident native service — matching the app's scale and its "one unified pipeline" invariant. (The Medium guides showing native Kotlin services solve *tracking after deliberate app kill*, a use case riding/walking recording does not need: the user ending the session should end it.) ([native-service pattern](https://medium.com/@ya0285981/how-i-built-a-reliable-background-location-service-in-flutter-using-kotlin-even-8ce01f193dd8), [package limitations](https://medium.com/@hasibulhasan3590/is-location-tracking-possible-after-app-is-killed-in-flutter-3b7d8ec992a4))

## Recommendation and slice plan

Slices (mirrored in TODO.md; each is vertical, tested, and leaves the tree green):

0. **Decision + spec** (this slice): research report; SPEC/ARCHITECTURE/README/AGENTS corrected so the app is no longer specified as view-only; strings reworded; no recording code yet.
1. **Recorder engine (pure Dart)**: `RecordingSession` state machine + `PositionSource` interface + incremental GPX writer (trkseg discipline). Synthetic-stream unit tests: jitter, stale fixes, accuracy rejections, pause/resume, flush boundaries, a torture case of a killed-session file.
2. **Android session**: manifest permissions (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`), geolocator stream with `ForegroundNotificationConfig`, Record action with the full permission flow, HUD chip, stop → unified import; Record hidden where location support is unavailable (desktop). Widget tests with a fake `PositionSource`; manual on-device verification per SPEC.
3. **Dashboard**: follow-camera + course-up marker during recording; stats panel (speed/distance/duration/moving avg + altitude when present); paused/stop affordances; strings en + it.
4. **Robustness**: salvage of un-finalized recordings on startup (toast + import), battery-optimization exemption advisory in Settings, GPX writer/reader round-trip fixture test regenerated via the fixture tool.
5. **Tilt (blocked upstream)**: adopt flutter_map pitch when released (bump version, `maxPitch`, gesture defaults, follow-camera under pitch); re-verify the released API against this research; decide fork-vs-wait if it stalls (owner call). Do *not* take `maplibre_gl` or `mapigrade` meanwhile.

## Open questions (owner decisions, with defaults)

1. **Interval and filters**: 1 s best-accuracy; drop fixes >50 m accuracy; `maxUpdateAge` 2 s. Default recommended — Strava/OpenTracks-class. Alternative: 2 s for battery shyness (harsher corridors).
2. **Battery-optimization exemption UX**: soft advisory link in Settings + a one-time hint after the first recording stops. Default: no blocking dialogs, no aggressive direct-intent permission flow.
3. **Post-notification denial**: proceed with a mute FGS (Android allows it silently on the notification shade). Default: proceed.
4. **Pause semantics in v1**: manual pause only (creates a trkseg break). Auto-pause-when-stationary is a later settings item. Default: manual.
5. **Salvage behavior on startup**: import the un-finalized file as-is with a toast (recommended, honest) vs discard silently (rejected) vs resume the session (deferred — heavier than the FGS-restart machinery it implies).
6. **Tilt strategy**: wait for upstream flutter_map pitch (default) vs bump to the `pitch-support` branch early (needs sign-off: tracking an unreleased branch in pubspec) vs commit to `maplibre_gl` rewrite now (rejected for effort/spec fit unless A stalls for months).
7. **Vector/3D-building look (Google-Maps parity)**: needs vector tile sources — a new network data path beyond raster OSM (SPEC rule change territory). Default: explicitly out of scope until the owner asks.

## Source Notes

| Source | Rating | Accessed |
|---|---|---|
| [Android developers — Foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types) | 5/5 | 2026-11-13 |
| [Android 14 — FGS types required](https://developer.android.com/about/versions/14/changes/fgs-types-required) and [FGS launch](https://developer.android.com/develop/background-work/services/fgs/launch) | 5/5 | 2026-11-13 |
| [Android developers — Request location permissions](https://developer.android.com/develop/sensors-and-location/location/permissions) | 5/5 | 2026-11-13 |
| [Android developers — Location battery](https://developer.android.com/develop/sensors-and-location/location/battery) / [Optimize](https://developer.android.com/develop/sensors-and-location/location/battery/optimize) | 5/5 | 2026-11-13 |
| [Play Console — foreground service policy](https://support.google.com/googleplay/android-developer/answer/13392821) | 5/5 | 2026-11-13 |
| [geolocator (pub.dev)](https://pub.dev/packages/geolocator), [AndroidSettings](https://pub.dev/documentation/geolocator_android/latest/geolocator_android/AndroidSettings-class.html), [ForegroundNotificationConfig](https://pub.dev/documentation/geolocator_android/latest/geolocator_android/ForegroundNotificationConfig-class.html), [Position](https://pub.dev/documentation/geolocator_platform_interface/latest/geolocator_platform_interface/Position-class.html) | 4/5 (package docs; one secondary mirror domain noticed for a fork) | 2026-11-13 |
| [flutter_map issue #1268 (tilt/pitch)](https://github.com/fleaflet/flutter_map/issues/1268), [PR #2283 (camera pitch)](https://github.com/fleaflet/flutter_map/pull/2283), [PR #2282 (pitch gestures)](https://github.com/fleaflet/flutter_map/pull/2282) | 5/5 (primary source; read the PR body directly) | 2026-11-13 |
| [maplibre_gl (pub.dev)](https://pub.dev/packages/maplibre_gl) and [flutter-maplibre-gl repo](https://github.com/maplibre/flutter-maplibre-gl) | 4/5 | 2026-11-13 |
| [mapigrade (GitHub)](https://github.com/greensopinion/mapigrade) | 4/5 (primary repo read; self-declared experimental status) | 2026-11-13 |
| [OsmAnd — interact with map](https://builder.osmand.net/docs/user/map/interact-with-map/), [topography](https://osmand.net/docs/user/plugins/topography/), [raster maps](https://osmand.net/docs/user/map/raster-maps/) | 3/5 (user docs, one via a mirror domain) | 2026-11-13 |
| [OpenTracks — improve your GPS geolocation](https://opentracks.app/en/article/improve-your-gps-geolocation-in-3-lessons) | 3/5 (practitioner guidance) | 2026-11-13 |
| [GPSLogger for Android](https://gpslogger.app/) | 3/5 (practitioner guidance) | 2026-11-13 |
| [GPX 1.1 schema](https://www.topografix.com/GPX/1/1/) | 5/5 | 2026-11-13 |
| [SO: How much battery does GPS consume?](https://stackoverflow.com/questions/44654818/how-much-battery-does-gps-consume) | 2/5 (anecdotal) | 2026-11-13 |
| [Medium posts on background tracking in Flutter](https://medium.com/@anabkhan8148/building-a-reliable-background-location-tracking-system-in-flutter-42067082915a), [Kotlin FGS pattern](https://medium.com/@ya0285981/how-i-built-a-reliable-background-location-service-in-flutter-using-kotlin-even-8ce01f193dd8) | 2/5 (blog engineering, useful for failure-mode catalog) | 2026-11-13 |

Caveats: PR #2283's API and merge timing may shift — the tilt slice must be re-verified against flutter_map's released changelog (published-then-merged stacks have changed shape before). Battery-drain figures are practitioner reports, not lab data; the app should not quote them in UI copy. Play policy pages change; the FGS declaration flow must be walked once with an actual release candidate before publishing.
