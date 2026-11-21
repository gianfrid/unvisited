Implements: —

# North-up button labelled "N"; exiting playback resets rotation to north

## Changes

1. `lib/ui/map_controls.dart`
   - `rotationModeIcon`/`rotationModeName`: in 'north' mode the button
     shows a bold letter **N** (a `Text('N')` in the button, replacing
     the `Icons.explore` compass) instead of an icon — clearly labelled
     north-up. 'course' keeps the travel arrow.
2. `lib/ui/app_model.dart`
   - `stopPlayback()` also calls `setMapRotation('north')`: exiting
     playback returns the camera to north-up, so the course arrow never
     lingers selected with nothing moving. Recording start/stop is
     untouched.
3. Tests
   - Unit: `stopPlayback` after a course-mode set resets `mapRotation`
     to 'north'.
   - Widget: the rotation button shows 'N' in north mode.

## Verification

`flutter analyze` clean, `flutter test` green.
