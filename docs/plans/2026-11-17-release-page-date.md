# Show the build's date on the rolling release page

Implements: —

## Problem

The rolling workflow (`.github/workflows/rolling.yml`) attaches each new APK
to the moving `rolling` GitHub release, but GitHub keeps a release's original
publish date — the page's headline date stays at the first publish while only
the asset refreshes. The release is named "Rolling" with no body, so nothing
on the page reflects which build is actually in the file.

## Fix

Stamp the release's name and body on every publish, from the same source the
app itself bakes into the APK (the latest commit's time — gradle's
`gitCommitTime()`), so the page and the app always agree:

1. New step after checkout (the checkout is already present):
   `COMMIT_DATE=$(git log -1 --format=%cs)` → `GITHUB_ENV`
   (`%cs` = short committer date, `YYYY-MM-DD`).
2. New step "Commits since the last published build": the `rolling` tag
   does not move (softprops updates the release in place but leaves the tag
   at the first publish — verified on the live repo), so the range cannot
   be `rolling..HEAD`. Instead read the last published SHA from the release
   body itself (`gh api repos/<repo>/releases/tags/rolling`, grep the
   `Commit: <sha>` line — the body format below guarantees it), then
   `git log --format='- %s (%h)' <sha>..HEAD`. Fallbacks: no release or an
   unparseable/unknown SHA (first dated build, or history rewritten) → the
   range is just `HEAD`, so the body still names the current commit. The
   GitHub token already in scope (`contents: write`) authorizes the read;
   `gh` is preinstalled on the runner.
3. `softprops/action-gh-release@v3` publish step:
   - `name: Rolling — ${{ env.COMMIT_DATE }}` (the most visible spot on the
     page; GitHub won't move the publish date, so the date rides in the title)
   - `body`: build number (= the APK's versionCode, `--build-number
     ${{ github.run_number }}`), commit date, then the commit list from step 2
   under a "What's new" heading, and a final machine-readable
   `Commit: <full sha>` line — the next run's range anchor. Enough to trace
     an installed build back to its source and to see what changed since the
     previous one.
   - `tag_name: rolling` unchanged — Obtanium tracks the asset
     `unvisited-rolling-arm64.apk` and the APK's version code, so the moving
     tag and the update detection are untouched.
   - softprops/action-gh-release patches an existing release's name/body when
     the tag already exists — the moving release is updated in place, not
     re-created.
4. Update the workflow's header comment to mention the dated release name.

The push that merges this change itself triggers the workflow, so the release
page picks up the dated name on that build — no manual dispatch needed.

## Verification

- `flutter analyze` / `flutter test` are unaffected (workflow-only change) but
  run anyway per the slice rules.
- The real verification is the next two runs: the first shows
  "Rolling — <commit date>" with a body naming the build and commit (no
  previous SHA yet — fallback range); the second lists the commits between
  the two builds.

## Out of scope

- The in-app build date — already correct (gradle bakes the commit time).
- Anything about release cadence or the local `tool/build_release_apk.sh`.
