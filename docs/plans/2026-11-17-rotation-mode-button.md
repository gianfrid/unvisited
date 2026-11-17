# Named rotation modes with a cycling button on the recording chip

Implements: —

## Problem

Research (`docs/navigation-follow-camera-prior-art-research-report.md` §1/§4.1)
shows every appliance and mature app surfaces rotation as a **named, user-
visible mode** — Garmin North Up / Track Up / 3D, Bryton Heading ↔ Compass
one-tap, OsmAnd's four `CompassMode`s — not a hidden Settings toggle.
Unvisited currently has only a Settings switch (`mapRotation` 'on'/'off'), and
a test even pins that the recording chip has no rotation toggle.

## Plan

1. Mode values: extend `mapRotation` from 'off'/'on' to **'north' / 'course' /
   'compass'**. `lib/storage/track_store.dart` maps the legacy stored values in
   `fromJson` ('off' → 'north', 'on' → 'course') so existing installs keep
   their setting.
2. `lib/ui/app_model.dart`: `mapRotation` getter/setter keep working over the
   new values; `setMapRotation` accepts the three modes.
3. `lib/ui/recording_dashboard.dart` `_onRecordingFix`:
   - 'north': move only (current 'off' behavior).
   - 'course': current 'on' behavior — GPS heading above the (hysteresis)
     gate, compass below it, marker pinned screen-up.
   - 'compass': rotation driven by the compass heading whenever one is
     available, even above the speed gate (OsmAnd compass-direction mode);
     hold the last rotation when no compass reading. The compass
     subscription must be active in both 'course' and 'compass' modes.
   - Marker pinning applies to both 'course' and 'compass'.
4. UI: a small icon button on the recording HUD chip cycles
   north → course → compass while recording (persisted via
   `setMapRotation`); tooltip names the current mode. Settings sheet: the
   boolean switch becomes a three-option control over the same setting.
   All new strings go into `lib/l10n/app_strings.dart` in **both** English
   and Italian (the strings test fails on any missing override).
5. `lib/ui/map_page.dart` marker: pinned screen-up for 'course' and 'compass';
   north-up angle = course + rotation for 'north' (as fixed in f8facf9).
6. Tests (`test/map_page_test.dart`, `test/app_model_test.dart`,
   `test/app_strings_test.dart` indirectly):
   - Replace the "chip has no rotation toggle" test with a cycling test:
     tap the chip's mode button → 'north' → 'course' → 'compass' → 'north',
     camera behavior per mode (north: no rotation; course: rotates to
     −heading; compass: rotates to −compass even at speed).
   - Store migration test: legacy 'on'/'off' settings load as 'course'/'north'.
   - Settings sheet renders the three options.
7. Verify: `flutter analyze` clean, `flutter test` passes; commit the plan
   and the change together.
