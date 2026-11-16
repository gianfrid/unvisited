# Nightly workflow: bump actions and pin the runner image

Implements: —

## Problem

CI annotations: actions/checkout@v4 and actions/setup-java@v4 run on
deprecated Node.js 20 (forced onto Node 24), setup-java v4 is deprecated,
and ubuntu-latest migrates to Ubuntu 26 on 2026-10-19. The build itself
still exits 1 (error detail not pasted — likely the signing step again).

## Plan

1. `.github/workflows/nightly.yml`:
   - `actions/checkout@v4` -> `@v6`, `actions/setup-java@v4` -> `@v5`
     (Node 24 based, no more deprecation warnings).
   - `runs-on: ubuntu-latest` -> `ubuntu-24.04` (pinned; avoids the
     Ubuntu 26 migration surprise).
2. Verify: yaml sanity via `flutter analyze`/`flutter test` (unaffected),
   commit plan + workflow, push to `slop`.
3. If the build still exits 1, the pasted log lacks the cause — add a
   keystore verification step (decode + `keytool -list`) or paste the
   failing step's log.
