#!/usr/bin/env sh
# Installs or removes the user-local desktop entry the session resolves the
# app icon by (see CMakeLists.txt and my_application.cc). A rebuild resets
# Exec to the bare name — icon resolution is unaffected there, but launching
# from the overview grid wants the entry this script installs, with Exec
# pointed at a built bundle.
#
#   linux/desktop-entry.sh install [bundle-dir]
#   linux/desktop-entry.sh uninstall
set -eu
me=$(basename "$0")
mode=${1:-}
[ -n "$mode" ] || { echo "usage: $me install [bundle-dir] | uninstall" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)

if [ -n "${XDG_DATA_HOME:-}" ]; then
  data_home=$XDG_DATA_HOME
elif [ -n "${HOME:-}" ]; then
  data_home=$HOME/.local/share
else
  echo "$me: no XDG_DATA_HOME and no HOME; cannot place the desktop entry" >&2
  exit 1
fi

desktop=$data_home/applications/gianfrid.unvisited.desktop
entry=$root/linux/gianfrid.unvisited.desktop

case $mode in
  install)
    if [ -n "${2:-}" ]; then
      bundle=$(cd "$2" && pwd)
    else
      # `flutter build linux` produces a release bundle, dev tests a debug one.
      bundle=
      for build_mode in release debug; do
        if [ -d "$root/build/linux/x64/$build_mode/bundle" ]; then
          bundle=$root/build/linux/x64/$build_mode/bundle
          break
        fi
      done
    fi
    if [ ! -x "$bundle/unvisited" ]; then
      echo "$me: no 'unvisited' binary in $bundle — build one: flutter build linux" >&2
      exit 1
    fi

    mkdir -p "$(dirname "$desktop")"
    sed "s|Exec=.*|Exec=$bundle/unvisited|" "$entry" > "$desktop"
    for icon in "$root"/linux/icons/*x*.png; do
      size=$(basename "$icon" .png)
      dest=$data_home/icons/hicolor/$size/apps
      mkdir -p "$dest"
      cp "$icon" "$dest/unvisited.png"
    done
    if command -v desktop-file-validate >/dev/null 2>&1; then
      desktop-file-validate "$desktop"
    fi
    # A user-local hicolor tree has no index.theme of its own (the real
    # theme lives in the system data dirs); the files are read as they are,
    # so refreshing the cache just warns. Only refresh a real theme.
    if command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && [ -f "$data_home/icons/hicolor/index.theme" ]; then
      gtk-update-icon-cache -q -f "$data_home/icons/hicolor" || true
    fi
    echo "desktop entry installed: $desktop (Exec=$bundle/unvisited)"
    ;;
  uninstall)
    rm -f "$desktop"
    find "$data_home/icons/hicolor" -name unvisited.png -path '*/apps/*' -delete 2>/dev/null || true
    echo "desktop entry removed"
    ;;
  *)
    echo "usage: $me install [bundle-dir] | uninstall" >&2
    exit 1
    ;;
esac
