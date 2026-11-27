#!/usr/bin/env bash
# Install the rolling Linux AppImage on this machine: copy it to a stable
# location, install the launcher entry and hicolor icons into the XDG dirs,
# or remove them again. Self-contained: the desktop entry and the per-size
# icons are read out of the AppImage itself (--appimage-extract needs no
# FUSE), so the only input is the downloaded unvisited-rolling-x86_64.AppImage.
#
#   tool/install_appimage.sh install [AppImage] [--prefix DIR]
#   tool/install_appimage.sh uninstall [--prefix DIR]
#
# Default prefix: ~/.local for a normal user, /usr/local when run as root.
# Layout under the prefix: bin/unvisited.AppImage,
# share/applications/gianfrid.unvisited.desktop,
# share/icons/hicolor/<size>/apps/unvisited.png — the XDG default layout for
# ~/.local, the standard system layout for /usr/local. A custom prefix works
# too, but its share/ must be in XDG_DATA_DIRS for the session to see the
# entry (a note is printed when it is not).
#
# Running the AppImage without installing keeps working: AppRun's one-shot
# first-run integration installs the same entry on first launch and never
# overwrites an existing one, so it does not conflict with an installed one.
set -euo pipefail

me=$(basename "$0")
usage() {
  cat >&2 <<EOF
usage: $me install [AppImage] [--prefix DIR]
       $me uninstall [--prefix DIR]

install    copy the AppImage to <prefix>/bin/unvisited.AppImage and install
           the desktop entry + icons under <prefix>/share
           (default prefix: ~/.local, or /usr/local when run as root;
            default AppImage: ./unvisited-rolling-x86_64.AppImage, then the
            repo-root artifact when run from a checkout)
uninstall  remove what install placed; app data under share/unvisited is kept
EOF
}

mode=${1:-}
case $mode in
  install|uninstall) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)

prefix=
appimage=
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || { echo "$me: --prefix needs a value" >&2; exit 2; }
      prefix=$2; shift 2 ;;
    --prefix=*) prefix=${1#--prefix=}; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "$me: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [ "$mode" = uninstall ]; then
        echo "$me: uninstall takes no AppImage argument" >&2; usage; exit 2
      fi
      [ -z "$appimage" ] || { echo "$me: more than one AppImage given" >&2; exit 2; }
      appimage=$1; shift ;;
  esac
done

if [ -z "$prefix" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    prefix=/usr/local
  else
    prefix=${HOME:?"$me: no HOME set; pass --prefix"}/.local
  fi
fi
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd)

bindir=$prefix/bin
share=$prefix/share
entry=$share/applications/gianfrid.unvisited.desktop
icons_root=$share/icons/hicolor

refresh_session() {
  if [ -f "$entry" ] && command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$entry" || true
  fi
  if [ -d "$share/applications" ] && command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$share/applications" >/dev/null 2>&1 || true
  fi
  # A user-local hicolor tree has no index.theme of its own (the real theme
  # lives in the system data dirs); only refresh a real theme.
  if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -f "$icons_root/index.theme" ]; then
    gtk-update-icon-cache -q -f "$icons_root" || true
  fi
}

warn_if_unseen() {
  # The session only scans XDG data dirs for desktop entries; a custom prefix
  # outside them still works when the AppImage is launched by hand.
  case ":${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:" in
    *":$share:"*) return ;;
  esac
  if [ "$share" != "${XDG_DATA_HOME:-$HOME/.local/share}" ]; then
    echo "$me: note: $share is not in XDG_DATA_DIRS; the launcher entry is only picked up once it is added there" >&2
  fi
}

case $mode in
  install)
    if [ -z "$appimage" ]; then
      for cand in ./unvisited-rolling-x86_64.AppImage "$root/unvisited-rolling-x86_64.AppImage"; do
        if [ -f "$cand" ]; then appimage=$cand; break; fi
      done
    fi
    if [ -z "$appimage" ]; then
      echo "$me: no AppImage given and none found at ./unvisited-rolling-x86_64.AppImage or $root/unvisited-rolling-x86_64.AppImage" >&2
      exit 1
    fi
    [ -f "$appimage" ] || { echo "$me: no such file: $appimage" >&2; exit 1; }
    appimage=$(cd "$(dirname "$appimage")" && pwd)/$(basename "$appimage")
    chmod +x "$appimage" 2>/dev/null || true

    mkdir -p "$bindir" "$share/applications"
    install -m 755 "$appimage" "$bindir/unvisited.AppImage"

    # Desktop entry + icons: from the repo when run in a checkout, otherwise
    # extracted from the AppImage itself (--appimage-extract needs no FUSE).
    work=
    trap '[ -n "$work" ] && rm -rf "$work" || true' EXIT
    if [ -f "$root/linux/gianfrid.unvisited.desktop" ]; then
      entry_src=$root/linux/gianfrid.unvisited.desktop
      icons_src=$root/linux/icons
    else
      work=$(mktemp -d)
      if ! (cd "$work" && "$appimage" --appimage-extract >/dev/null); then
        echo "$me: could not extract $appimage with --appimage-extract" >&2
        exit 1
      fi
      entry_src=$work/squashfs-root/gianfrid.unvisited.desktop
      icons_src=$work/squashfs-root/usr/bin/data/icons
    fi
    [ -f "$entry_src" ] || { echo "$me: no gianfrid.unvisited.desktop found inside $appimage" >&2; exit 1; }

    # On a machine without usable FUSE the image cannot mount; run it
    # extracted instead (the runtime still sets $APPIMAGE, so AppRun's
    # first-run integration is unaffected).
    exec_arg=$bindir/unvisited.AppImage
    fuse_ok=1
    [ -e /dev/fuse ] || fuse_ok=0
    if ! command -v fusermount >/dev/null 2>&1 && ! command -v fusermount3 >/dev/null 2>&1; then
      fuse_ok=0
    fi
    [ "$fuse_ok" -eq 1 ] || exec_arg="$exec_arg --appimage-extract-and-run"

    sed "s|^Exec=.*|Exec=$exec_arg|" "$entry_src" > "$entry"
    for png in "$icons_src"/*x*.png; do
      [ -e "$png" ] || continue
      size=$(basename "$png" .png)
      mkdir -p "$icons_root/$size/apps"
      cp "$png" "$icons_root/$size/apps/unvisited.png"
    done

    refresh_session
    warn_if_unseen
    echo "installed: $bindir/unvisited.AppImage"
    echo "desktop entry: $entry (Exec=$exec_arg)"
    ;;
  uninstall)
    rm -f "$bindir/unvisited.AppImage" "$entry"
    find "$icons_root" -name unvisited.png -path '*/apps/*' -delete 2>/dev/null || true
    refresh_session
    echo "uninstalled from $prefix (app data under $share/unvisited was kept)"
    ;;
esac
