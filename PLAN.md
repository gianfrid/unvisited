# PLAN: Automatic release-APK build on TODO-item completion (TODO.md item 4)

TODO.md item: "Automatic release-APK build on TODO-item completion" —
a script that runs `flutter build apk --release --split-per-abi
--target-platform=android-arm64` in the background when a TODO.md item
is completed. The agent does NOT wait for the build and the next prompt
is NOT blocked: the script returns immediately after launching the
build. At least 5 minutes between builds, measured from the previous
build's end; a completion inside the window (or while a build is still
running) skips — no queueing. Failures are logged, no retry loop.

One commit: the script + the workflow wiring + PLAN.md + removal of the
TODO.md entry. Verification: shell-level checks with a stubbed `flutter`
(the real release build is not run during the slice).

## The change

1. `tool/build_release_apk.sh` (bash, executable):
   - State dir: `${UNVISITED_BUILD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/unvisited-build}`
     — outside the repo, so no build state ever dirties the working tree.
   - Files there: `last_build_end` (epoch seconds of the previous build's
     end, success or failure), `build.pid` (present while a build is in
     flight), and `build.log` (appended build output).
   - Skip rule: if `build.pid` is present and its process is alive, or
     `last_build_end` exists and `now - last_build_end < 300`, print a skip
     message and exit 0 without building.
   - Otherwise launch `flutter build apk --release --split-per-abi
     --target-platform=android-arm64` detached in the background
     (`nohup ... >>build.log 2>&1 &`, pid recorded in `build.pid`), and
     return immediately with exit 0. A small wrapper inside the detached
     shell removes `build.pid` and writes `now` to `last_build_end` when
     the build exits — whether it succeeded or failed (a failed build
     also ends a window, per the triage). The script's own exit code is
     always 0 when it merely launched or skipped; the build's outcome
     lives in `build.log`.
2. Workflow wiring: add one step to AGENTS.md's Task workflow — after a
   TODO.md item is committed, run `tool/build_release_apk.sh` and do NOT
   wait for it; the build runs in the background and never blocks the
   next prompt.
3. Remove TODO.md item 4 in the same commit.

## Verification (no real release build in the slice)

- Put a stub `flutter` first on `PATH` that sleeps ~2 s, logs its
  arguments, and exits 0. Run the script: it returns immediately (well
  under 2 s) and the stub is running in the background.
- Run the script again while the stub build is still in flight: it must
  skip (pid alive) and the stub must still have been called once.
- Wait for the stub build to finish, run the script again: it must skip
  (inside the 5-minute window from the build's end).
- Backdate `last_build_end` by 10 minutes, run again: the stub is
  called a second time.
- Stub exits 1: the failure lands in `build.log`, `build.pid` is
  cleaned up, and `last_build_end` still updates.
- `flutter analyze` clean, `flutter test` pass (the script is not part
  of the Dart tree; analyze/test are unaffected but run anyway per the
  workflow).

## Out of scope

- Running a real release build during the slice (too slow; verified via
  the stub). The first real run happens naturally at the next TODO-item
  completion.
- Blocking/waiting on the build in any form — explicitly not wanted.
- Signing config, APK distribution, artifact cleanup, CI integration.
