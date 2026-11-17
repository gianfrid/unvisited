# Push-only rolling release: drop the daily cron, delete the old nightly release

Implements: —

## Answer

The user wants builds only on push. Remove the `schedule` trigger from
`.github/workflows/rolling.yml` (push to `slop` and `workflow_dispatch`
remain) and update the header comment. Separately, delete the legacy
`nightly` GitHub release (and its tag) on `gianfrid/unvisited` via the
GitHub API — destructive and irreversible, explicitly requested.

## Plan

1. `.github/workflows/rolling.yml`: drop the `schedule:` block and the
   "plus a daily cron" wording in the header comment.
2. Delete the `nightly` release on GitHub with `gh release delete nightly
   --cleanup-tag --yes` (release + tag + APK asset gone for good).
3. Verify: workflow YAML parses, `flutter analyze` clean, `flutter test`
   passes. Commit plan + workflow change together.
