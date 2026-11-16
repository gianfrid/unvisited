# Nightly alpha APK on GitHub Actions, distributed via Obtanium

Implements: —

## Answer

Build nightly on GitHub Actions — this repo is public, so standard runners
are available — no local uploads. Obtanium tracks a GitHub release
directly: it polls the `nightly` release and downloads the APK asset
matching a pattern.

## Plan

1. `android/app/build.gradle.kts`: release `signingConfig` reads a keystore
   from env vars (`UNVISITED_KEYSTORE_B64`, `UNVISITED_KEYSTORE_PASSWORD`,
   `UNVISITED_KEY_ALIAS`, `UNVISITED_KEY_PASSWORD`) when present, else keeps
   the debug signing — local builds unchanged, CI signs with repo secrets
   (one keystore created with `keytool`, added as 4 secrets in GitHub repo
   settings; nothing secret is committed).
2. `.github/workflows/nightly.yml`: cron `0 3 * * *` (+ manual
   `workflow_dispatch`), `ubuntu-latest`, `subosito/flutter-action`, then
   `flutter build apk --release --split-per-abi --target-platform=android-arm64`
   with `--build-name 1.0.0-alpha --build-number ${{ github.run_number }}`
   (alpha label in versionName; run_number is a monotonically increasing
   versionCode so Obtanium sees each nightly as an update). Upload
   `build/app/outputs/flutter-apk/app-arm64-release.apk` to a moving
   `nightly` release (tag `nightly`, asset name `unvisited-arm64.apk`) via
   `softprops/action-gh-release`.
3. Obtanium (user-side, one-time): add app from GitHub repo
   `gianfrid/unvisited`, release/asset regex targeting the nightly APK.
4. Verify: `flutter analyze` clean, `flutter test` passes; the workflow file
   is validated by running it once via `workflow_dispatch` after the secrets
   are set. Commit plan + gradle change + workflow together.
