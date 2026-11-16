# Auto-detect the release keystore type (PKCS12 vs JKS) in gradle

Implements: —

## Problem

CI fails at `:app:packageRelease` with `KeytoolException: Failed to read
key from store "/tmp/unvisited-release*.jks": Tag number over 30 is not
supported`. Modern keytool defaults to PKCS12, but Gradle's signing config
defaulted to reading the env-supplied keystore as JKS — a PKCS12 file
parsed as JKS fails exactly with that ASN.1 tag error.

## Plan

1. `android/app/build.gradle.kts`: in the env-based `release` signing
   config, set `storeType` from the keystore's magic bytes — JKS files
   start with `FE ED FE ED`, anything else (PKCS12) is ASN.1 `30 ...`.
   No new secret, works for keystores created with or without
   `-storetype`.
2. Verify: `flutter analyze` clean, `flutter test` passes (no JDK here,
   so no local gradle run — CI validates). Commit plan + change, push to
   `slop`.
