# Rolling release APK on every push, distributed via Obtanium

Implements: —

## Answer

Rename the existing nightly workflow to a single `rolling` workflow and add a
push trigger, so every push to `slop` (the repo's only branch) builds a fresh
signed arm64 release APK and publishes it to the moving `rolling` release
(tag `rolling`, asset `unvisited-rolling-arm64.apk`), where Obtanium picks it
up from the GitHub repo `gianfrid/unvisited`. The daily cron schedule and
manual dispatch stay, so the same rolling release is refreshed nightly as
before — now also on every push. Because it is one workflow, the
`github.run_number` versionCode counter stays monotonic across all triggers,
so Obtanium sees every build as an update.

## Plan

1. `git mv .github/workflows/nightly.yml .github/workflows/rolling.yml`, then
   edit it:
   - name/header comments: "Rolling release APK"; document the three
     triggers (push to `slop`, cron `0 3 * * *`, `workflow_dispatch`) and the
     `rolling` tag / `unvisited-rolling-arm64.apk` asset.
   - `on:` gains `push: branches: [slop]`.
   - `concurrency.group`: `nightly` → `rolling`.
   - `--build-name "1.0.0-rolling"` (was `1.0.0-alpha`); `--build-number`
     stays `${{ github.run_number }}`.
   - Publish step: `tag_name: rolling`, name "Rolling", asset copied to
     `unvisited-rolling-arm64.apk`. Pinned `ubuntu-24.04`, Temurin 17,
     `subosito/flutter-action`, keystore decode/verify step and the four
     `UNVISITED_*` secrets all unchanged — no new secrets needed.
2. Obtanium (user-side, one-time): point the existing app entry at the
   `rolling` release / `unvisited-rolling-arm64.apk` asset in repo
   `gianfrid/unvisited` (previously `nightly` / `unvisited-nightly-arm64.apk`).
3. Verify: workflow YAML parses (`python3 -c yaml.safe_load`), `flutter
   analyze` clean, `flutter test` passes. Commit plan + workflow rename
   together.
