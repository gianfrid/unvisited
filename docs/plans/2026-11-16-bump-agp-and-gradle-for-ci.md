# Bump AGP and Gradle wrapper so CI's newer Flutter accepts the build

Implements: —

## Problem

The nightly workflow fails at `assembleRelease`: the runner's current
Flutter stable requires Android Gradle Plugin >= 9.1.1, but
`android/settings.gradle.kts` pins AGP 9.1.0 (local Flutter 3.47.9 is
older and accepted it). The same log warns Gradle 9.3.1 will soon be
dropped in favor of >= 9.5.0.

## Plan

1. `android/settings.gradle.kts`: AGP `9.1.0` -> `9.1.1` (the stated
   minimum; AGP 9.1.x runs on Gradle 9.x and JDK 17, which the workflow
   already provides).
2. `android/gradle/wrapper/gradle-wrapper.properties`: Gradle `9.3.1` ->
   `9.5.0` (the warning's stated floor), so the next Flutter bump does not
   break the build again.
3. Verify locally as far as this environment allows (no JDK here, so no
   gradle run): `flutter analyze` clean, `flutter test` passes; CI's next
   run validates the gradle change. Commit plan + change, push to `slop`.
