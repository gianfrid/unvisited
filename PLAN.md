# Slice 10 — soft POST_NOTIFICATIONS ask; open-decisions defaults closed out

## Context

TODO's open-decisions line confirms five defaults; four are already
delivered (1 s interval in `AndroidPositionSource`, the soft battery
advisory in Settings, manual pause from slice 5, salvage-as-import from
the robustness slice). The one gap is the research report's permission
table: `POST_NOTIFICATIONS` (API 33+) is in the manifest but never
requested — "soft, never blocking recording". geolocator has no
notification-permission API, so the ask rides the existing
`unvisited/host` channel (same pattern as the battery advisory), handset
API 33 gating: below 33 the permission does not exist and the answer is
granted.

## Steps

1. `MainActivity.kt` — new host-channel method
   `requestPostNotifications`:
   - granted immediately when the permission exists not at all (< API 33)
     or is already held;
   - otherwise fires `requestPermissions` once and answers with the
     grant result via `onRequestPermissionsResult` (pending-result
     pattern like `pickDirectory`, with `already_active` re-entry guard).
2. `lib/ui/app_model.dart` — `Future<bool?> requestPostNotifications()`:
   invokes the method, returns null (or false) on any
   MissingPluginException/PlatformException — desktop and tests fall
   back cleanly, mirroring `batteryOptimizationExcluded`.
3. `lib/ui/map_page.dart` — `_startRecording` fires the request without
   awaiting it (`unawaited`) right before the session starts: the ask is
   soft (one system dialog at the first tap, no second popup that same
   run since Android remembers), refusal never blocks or fails the
   session, and the FGS proceeds mute as the confirmed default says.
   Honor a one-shot-per-run flag so repeated Record taps do not nag.
4. Tests (`test/app_model_test.dart`, host-channel mock pattern):
   - model method surfaces the channel's grant result (true / false);
   - a `notImplemented` host answers null (no crash on desktop);
   - a widget-level tap of Record issues the request alongside the
     session start (map-page test with the channel mocked, recording
     still starts when the mock answers false).

## Verification

- `flutter analyze` clean; `flutter test` all pass.
- Commit includes PLAN.md, deletes the open-decisions TODO entry (its
  five defaults are then all delivered in code), and carries PLAN.md
  over unmodified.
