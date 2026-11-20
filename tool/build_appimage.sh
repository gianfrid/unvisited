#!/usr/bin/env bash
# Build the Linux AppImage and leave it at the repo root as
# unvisited-rolling-x86_64.AppImage. Called by the rolling.yml workflow;
# runnable locally with just the Flutter SDK and the Linux desktop build
# deps (ninja, libgtk-3-dev) installed.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_NAME="1.0.0-rolling"
BUILD_NUMBER="1"
while [ $# -gt 0 ]; do
  case "$1" in
    --build-name) BUILD_NAME="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

flutter pub get
flutter build linux --release \
  --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER"

# Stage the AppDir in a scratch dir; only the packed AppImage lands in the
# repo tree.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/AppDir"

# The bundle's runner resolves lib/ and data/ relative to the executable,
# so the whole bundle lives under usr/bin — linuxdeploy's usual usr/bin +
# usr/lib split would break it.
BUNDLE=build/linux/x64/release/bundle
install -d "$APPDIR/usr/bin"
cp -r "$BUNDLE"/* "$APPDIR/usr/bin/"
cp assets/icon/icon-1024.png "$APPDIR/.DirIcon"
cp assets/icon/icon-1024.png "$APPDIR/unvisited.png"
# Desktop identity: the app reports itself as gianfrid.unvisited (see
# linux/CMakeLists.txt / my_application.cc), and GNOME resolves the running
# window's dock icon by matching that id against a desktop file NAMED
# gianfrid.unvisited.desktop (see linux/CMakeLists.txt's Wayland notes).
# So the AppImage ships the repo's own committed entry verbatim — the one
# the dev flow installs into the user's XDG dirs — rather than a hand-made
# one under a different name, which no session could ever match.
install -m 644 linux/gianfrid.unvisited.desktop "$APPDIR/gianfrid.unvisited.desktop"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# First-run desktop integration, then straight into the app.
#
# GNOME resolves the running window's dock icon by matching the app id
# (gianfrid.unvisited) against a desktop entry of that name in the user's
# XDG dirs (see linux/CMakeLists.txt) — there is no per-window mechanism
# on Wayland. The dev bundle installs create the entry; this AppImage
# installs it on first run instead, mirroring linux/desktop-entry.sh:
# the bundled entry with Exec rewritten to the AppImage's own path, and
# the bundle's per-size icons into the user's hicolor tree.
#
# It runs before the app maps its window, so the icon resolves on this
# very first launch — no restart. One-shot (an existing entry — e.g. a
# dev checkout's — is never overwritten), only when launched as an
# AppImage ($APPIMAGE is set by the runtime; extracted runs skip it),
# and best-effort: a read-only XDG dir must never keep the app from
# starting.
here=$(dirname "$(readlink -f "$0")")

if [ -n "${APPIMAGE:-}" ] && [ -n "${HOME:-}" ] \
  && [ "${APPIMAGE_SKIP_INTEGRATION:-0}" != 1 ]; then
  data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
  entry=$data_home/applications/gianfrid.unvisited.desktop
  if [ ! -e "$entry" ]; then
    mkdir -p "$(dirname "$entry")" 2>/dev/null \
      && sed "s|^Exec=.*|Exec=$APPIMAGE|" \
        "$here/gianfrid.unvisited.desktop" > "$entry" 2>/dev/null \
      || true
    for png in "$here"/usr/bin/data/icons/*x*.png; do
      [ -e "$png" ] || continue
      size=$(basename "$png" .png)
      mkdir -p "$data_home/icons/hicolor/$size/apps" 2>/dev/null \
        && cp "$png" "$data_home/icons/hicolor/$size/apps/unvisited.png" \
        || true
    done
  fi
fi

exec "$here/usr/bin/unvisited" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# The distributed image is run by users other than the one who packaged
# it, and flutter's build dir or the source checkout can carry
# restrictive modes (a 0600 desktop file, incremental-rebuild modes), so
# normalize read/traverse permissions on the whole AppDir in one place.
# appimagetool refuses to embed anything less readable than 0644.
chmod -R a+rX "$APPDIR"

# appimagetool has no usable stable release (the 1.9.x tags are the
# in-progress rewrite, which hangs); the continuous build is the supported
# tool. Timeouts/retries keep a stalled CDN connection from hanging CI.
wget -q --timeout=30 --tries=3 -O "$WORK/appimagetool" \
  "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
chmod +x "$WORK/appimagetool"

# APPIMAGE_EXTRACT_AND_RUN works with and without usable FUSE (GitHub
# runners have none), so it is used unconditionally.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$WORK/appimagetool" "$APPDIR" \
  unvisited-rolling-x86_64.AppImage

echo "AppImage written to $(pwd)/unvisited-rolling-x86_64.AppImage"
