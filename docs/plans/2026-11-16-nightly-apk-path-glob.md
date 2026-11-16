# Nightly workflow: glob the arm64 APK path

Implements: —

## Problem

The release build succeeds but produces
`app-arm64-v8a-release.apk` (ABI-suffixed name); the workflow's `cp`
looks for `app-arm64-release.apk` and fails.

## Plan

1. `.github/workflows/nightly.yml`: `cp build/app/outputs/flutter-apk/app-arm64-*-release.apk unvisited-nightly-arm64.apk`
2. Commit plan + workflow, push to `slop`.
