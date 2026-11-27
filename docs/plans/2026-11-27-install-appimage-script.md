Implements: —

# Install script for the rolling AppImage

## Goal

A single self-contained `tool/install_appimage.sh` that an end user runs with
the downloaded `unvisited-rolling-x86_64.AppImage` to install Unvisited
properly on a Linux desktop: the AppImage is copied to a stable location, a
launcher entry plus hicolor icons are installed into the XDG dirs, and
`uninstall` reverses it. Running the AppImage bare keeps working as today
(AppRun's one-shot first-run integration stays as the zero-install path; it
never overwrites an existing entry, so it does not conflict with an installed
one).

Scope confirmed by the owner on 2026-11-27: the script only. Attaching it to
the rolling release's assets and documenting it in README.md were considered
and deliberately left out of this slice.

## Design decisions

- **Shape.** `tool/install_appimage.sh`, bash with `set -euo pipefail`,
  mirroring `tool/build_appimage.sh`'s option parsing. Modes:
  `install [AppImage] [--prefix DIR]` and `uninstall [--prefix DIR]`. The
  AppImage argument defaults to `./unvisited-rolling-x86_64.AppImage`, falling
  back to the repo-root artifact when run from a checkout.
- **Prefix layout, uniform for user and system installs.** Default prefix is
  `~/.local` for a normal user and `/usr/local` when euid is 0 (sudo). From the
  prefix: `bindir=$prefix/bin` (installed image is `$bindir/unvisited.AppImage`,
  mode 755), desktop entry at `$prefix/share/applications/gianfrid.unvisited.desktop`,
  icons at `$prefix/share/icons/hicolor/<size>/apps/unvisited.png`. For
  `~/.local` that is exactly the XDG default layout; for `/usr/local` the
  standard system layout. A custom prefix outside XDG_DATA_DIRS gets a printed
  note that the session will not scan it.
- **Self-contained.** The desktop entry and the per-size icons are taken from
  the AppImage itself: `--appimage-extract` into a `mktemp -d` scratch dir
  (works without FUSE), reading `squashfs-root/gianfrid.unvisited.desktop` and
  `squashfs-root/usr/bin/data/icons/*x*.png`, with `Exec` rewritten to the
  installed image's absolute path. When run from a repo checkout
  (`linux/gianfrid.unvisited.desktop` exists next to the script) the repo's
  committed entry and `linux/icons/` are used instead, so no extraction is
  needed in the dev flow.
- **FUSE-less machines.** If `/dev/fuse` is missing or neither `fusermount` nor
  `fusermount3` is on PATH, ` --appimage-extract-and-run` is appended to the
  entry's `Exec` so the launcher still works (the runtime still sets
  `$APPIMAGE`, so AppRun's integration is unaffected).
- **Best-effort session refresh**, same guards as `linux/desktop-entry.sh`:
  `desktop-file-validate` and `update-desktop-database` when available;
  `gtk-update-icon-cache` only when the target hicolor tree has an
  `index.theme`.
- **Uninstall** removes the installed AppImage, the desktop entry and the
  `unvisited.png` hicolor icons under the prefix — and never the app's data
  (`$prefix/share/unvisited` for a `~/.local` prefix is app data, not ours).

## Steps

1. Write `tool/install_appimage.sh` (executable) per the design above.
2. **Verify:** `shellcheck tool/install_appimage.sh` clean; functional test in
   this environment against the repo-root AppImage with scratch prefixes:
   end-user mode (script + AppImage alone in a temp dir, exercising the
   `--appimage-extract` branch) install → assert `$prefix/bin/unvisited.AppImage`
   executable, entry `Exec` points at it, all 8 icon sizes landed; uninstall →
   assert everything removed and a stand-in `share/unvisited/index.json`
   survives. Repo mode (run from the checkout, restricted PATH without
   fusermount) → assert the committed entry/icons are used, the image is
   byte-identical, and `Exec` gains `--appimage-extract-and-run`. CLI contract:
   no args/unknown option/positional on uninstall → exit 2, `--help` → 0,
   missing AppImage → exit 1. `flutter analyze` clean, `flutter test` pass (no
   Dart changes).
3. **Commit** script + this plan, message
   "Add an install script for the rolling AppImage".

## Non-goals

- No appimaged / AppImageLauncher dependency, no zsync/update metadata, no
  signing, no arm64, no GUI menu editor.
- No change to AppRun's first-run self-integration (zero-install path stays).
- No changes to the dev-flow `linux/desktop-entry.sh`, the rolling workflow,
  or README.md (owner-descoped from this slice).
