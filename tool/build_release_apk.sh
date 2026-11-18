#!/usr/bin/env bash
# Launches a release APK build in the background and returns immediately.
#
# On-demand only (see AGENTS.md): invoked when the user explicitly asks
# for a release APK, never automatically after commits. The caller never
# waits — the next prompt is never blocked by a build. At least 5 minutes must pass between builds, measured from
# the previous build's end (success or failure); a build still in flight
# also makes later calls skip. No queueing, no retry loop: failures land
# in build.log and the next call after the window tries again.
#
# Build state lives outside the repo (override with
# UNVISITED_BUILD_STATE_DIR) so no build state ever dirties the tree.
set -u

command -v flutter >/dev/null 2>&1 || {
    echo "build_release_apk: flutter not on PATH; skipping" >&2
    exit 0
}

state_dir="${UNVISITED_BUILD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/unvisited-build}"
mkdir -p "$state_dir"
pid_file="$state_dir/build.pid"
end_file="$state_dir/last_build_end"
log_file="$state_dir/build.log"
window_seconds=300

now_epoch() { date +%s; }

if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "build_release_apk: a build is already running (pid $(cat "$pid_file")); skipping"
    exit 0
fi

if [ -f "$end_file" ]; then
    elapsed=$(( $(now_epoch) - "$(cat "$end_file")" ))
    if [ "$elapsed" -lt "$window_seconds" ]; then
        remaining=$(( window_seconds - elapsed ))
        echo "build_release_apk: last build ended ${elapsed}s ago (window ${window_seconds}s); skipping (retry in ${remaining}s)"
        exit 0
    fi
fi

# The detached shell carries the session bookkeeping: drop the pid file
# and stamp the window when the build exits — success or failure alike.
(
    flutter build apk --release --split-per-abi --target-platform=android-arm64 \
        >>"$log_file" 2>&1
    rc=$?
    echo >>"$log_file" "build_release_apk: build exited with rc=$rc at $(date -Iseconds)"
    date +%s >"$end_file"
    rm -f "$pid_file"
) &
build_pid=$!
echo "$build_pid" >"$pid_file"
echo "build_release_apk: launched release APK build (pid $build_pid); log: $log_file"
exit 0
