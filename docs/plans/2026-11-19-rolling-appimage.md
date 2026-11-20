Implements: —

# Linux AppImage built by CI (rolling channel)

## Goal

Every push to `slop` (or manual dispatch) produces, besides the existing
rolling APK, a Linux x86_64 AppImage, attached to the same moving `rolling`
GitHub release as `unvisited-rolling-x86_64.AppImage`.

## Design decisions

- **One publish step, not two.** The APK publish owns the release body
  (date, commit list, `Commit:` anchor). Rather than racing a second
  `softprops/action-gh-release` step for the AppImage, the AppImage is built
  in the same `build` job and added to the existing publish step's `files:`
  list. No race, one release body, both assets.
- **Recipe in a script, CI is a thin caller.** `tool/build_appimage.sh`
  (bash, mirroring `tool/build_release_apk.sh`'s location) holds the whole
  recipe: `flutter build linux --release`, stage AppDir, appimagetool
  continuous. CI (and a developer with `flutter` + `ninja-build` +
  `libgtk-3-dev`) just runs it.
- **AppDir staging:** the Flutter Linux bundle resolves `lib/`
  and `data/` relative to the executable, so the whole bundle goes under
  `usr/bin` (not linuxdeploy's usr/bin + usr/lib split). `AppRun` is a
  plain `sh` exec wrapper. `appimagetool` continuous build with
  `APPIMAGE_EXTRACT_AND_RUN=1` (no FUSE needed on GitHub runners),
  wget with timeout/retries.
- **Metadata:** desktop entry `Name=Unvisited`, `Icon=unvisited`,
  Categories `Utility;` (freedesktop-valid). `.DirIcon` + top-level icon
  from `assets/icon/icon-1024.png` (existing committed artifact; the 256 px
  hicolor PNGs live only in the generated build dir).
- **Versioning:** build with `--build-name "1.0.0-rolling"
  --build-number ${{ github.run_number }}`, matching the APK step, so both
  assets report the same version.
- **First-run desktop integration in AppRun.** A stock machine has no
  `gianfrid.unvisited.desktop` in the user's XDG dirs, so GNOME shows a
  generic dock icon for the running window (on Wayland there is no
  per-window mechanism; the entry is the only resolver). AppRun therefore
  mirrors the dev flow's `linux/desktop-entry.sh install`: on first run
  (entry missing, `$APPIMAGE` set — i.e. launched as an AppImage, not
  extracted), it installs the bundled desktop entry with
  `Exec=$APPIMAGE` and the bundle's own per-size PNGs into the user's
  hicolor tree, then execs the binary. This happens *before* the window
  maps, so no restart is needed — and it is one-shot, never overwriting
  an existing entry (a dev checkout's entry is left alone), and
  failure-tolerant: the app must start even if integration cannot be
  written. No AppImageLauncher/appimaged dependency.

## Steps

1. **Add `tool/build_appimage.sh`** (executable). Content per the design
   above: build → stage AppDir in `mktemp -d` scratch → write desktop
   entry, `.DirIcon`, `unvisited.png`, `AppRun` → fetch
   `appimagetool-x86_64.AppImage` (continuous, `--timeout=30 --tries=3`)
   → `ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1` →
   `unvisited-rolling-x86_64.AppImage` at the repo root. Runner pinned
   workflow style: no version assumptions beyond the pinned Flutter 3.47.9
   already used in the workflow (the script uses whatever `flutter` is on
   PATH).
2. **Extend `.github/workflows/rolling.yml`**, inside the existing `build`
   job, after the APK build step:
   - step "Linux desktop build deps": `sudo apt-get update && sudo apt-get
     install -y ninja-build libgtk-3-dev` (runner image lacks the GTK3
     headers Flutter's Linux runner links against).
   - step "Build AppImage (rolling)": run `tool/build_appimage.sh
     --build-name "1.0.0-rolling" --build-number "${{ github.run_number }}"`
     (the script takes optional `--build-name`/`--build-number` flags and
     defaults to `1.0.0-rolling`/`1`, so it is runnable locally too).
   - publish step: add `unvisited-rolling-x86_64.AppImage` to `files:`.
3. **README.md**: note the rolling release also carries the Linux AppImage
   in the run/build section (user-facing, one sentence).
4. **Verify:** `flutter analyze` clean, `flutter test` pass. Locally
   attempt `tool/build_appimage.sh` (desktop deps present on this machine
   per the Linux dev target) to smoke-test the recipe; if the local machine
   is missing a dep, the script's failure output is the check. Bash:
   `shellcheck tool/build_appimage.sh` if available (not enforced).
5. **Commit** script + workflow + README + this plan, message
   "CI: build and publish a Linux AppImage on the rolling channel".

## Non-goals

- No tag/release workflow for unvisited (no `v*` channel exists yet) —
  when one is added, the same script is the recipe.
- No arm64 AppImage, no signing/update metadata (AppStream/zsync).
- No changes to the Linux runner's own XDG install logic.
