#!/usr/bin/env bash
# =============================================================================
# Build OmaDVD-Player.AppImage
#
# Bundles mpv and its decoding stack -- crucially including libdvdcss, which no
# distribution ships by default and without which every commercial disc fails
# with a cryptic "Error reading NAV packet". That single library is most of the
# reason this is an AppImage at all.
#
# What is deliberately NOT bundled matters just as much. Shipping a copy of the
# graphics, display-server or C++ runtime stack is the classic way to build an
# AppImage that runs perfectly on the machine that made it and segfaults
# everywhere else: the host's Mesa drivers get loaded into a process holding our
# older libstdc++, and nothing good follows. Those come from the host.
#
# Usage: packaging/build-appimage.sh [-o OUTPUT.AppImage]
# =============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
BUILD=${BUILD_DIR:-$ROOT/build}
APPDIR=$BUILD/AppDir
OUT=${OUT:-$ROOT/OmaDVD-Player-x86_64.AppImage}
TOOLCACHE=${TOOLCACHE:-$HOME/.cache/omadvd-build}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUT=$2; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# ── Libraries that must come from the host, never from us ────────────────────
# Each line is a basename prefix matched against the start of the soname.
#   glibc + gcc runtime : must match the host's Mesa/driver stack exactly
#   graphics / GPU      : the driver IS the machine; bundling it defeats itself
#   display server      : wayland/X protocol libs pair with the host compositor
#   audio servers       : pipewire/pulse/alsa clients pair with the host daemon
#   fontconfig stack    : couples to the host's font cache and config
#   system services     : udev/dbus/systemd talk to the host's own daemons
EXCLUDE='
ld-linux ld-linux-x86-64 libc libm libdl libpthread librt libresolv libnsl
libutil libanl libBrokenLocale libcrypt libstdc++ libgcc_s libgomp
libGL libGLX libGLdispatch libEGL libOpenGL libglapi libgbm libdrm libvulkan
libva libva-drm libva-x11 libva-wayland libvdpau libnvidia libcuda
libwayland-client libwayland-server libwayland-cursor libwayland-egl
libX11 libX11-xcb libxcb libxcb-dri2 libxcb-dri3 libxcb-glx libxcb-present
libxcb-randr libxcb-render libxcb-shape libxcb-shm libxcb-sync libxcb-xfixes
libXext libXrandr libXrender libXi libXfixes libXcursor libXinerama libXss
libXau libXdmcp libxkbcommon libxkbcommon-x11 libxshmfence
libasound libpulse libpulse-simple libpipewire-0.3 libjack libsndio
libfontconfig libfreetype libharfbuzz
libudev libsystemd libdbus-1 libselinux libcap libgpg-error libgcrypt
'

is_excluded() {
  local base=${1%%.so*}
  local e
  for e in $EXCLUDE; do [ "$base" = "$e" ] && return 0; done
  return 1
}

# ── Preflight ────────────────────────────────────────────────────────────────
MPV_BIN=${MPV_BIN:-$(command -v mpv)} || { echo "mpv not found" >&2; exit 1; }
say "using mpv: $MPV_BIN ($("$MPV_BIN" --version | head -1))"

# libdvdcss is loaded by libdvdread with dlopen(), so it never appears in ldd
# output. If we do not copy it by hand, the AppImage builds cleanly and then
# cannot play a single commercial disc.
CSS=""
for d in /usr/lib /usr/lib64 /usr/local/lib /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu; do
  [ -e "$d/libdvdcss.so.2" ] && { CSS=$d/libdvdcss.so.2; break; }
done
[ -n "$CSS" ] || { echo "libdvdcss.so.2 not found -- install libdvdcss first" >&2; exit 1; }
say "found libdvdcss: $CSS"

APPIMAGETOOL=${APPIMAGETOOL:-$TOOLCACHE/appimagetool.AppImage}
if [ ! -x "$APPIMAGETOOL" ]; then
  mkdir -p "$TOOLCACHE"
  say "fetching appimagetool"
  curl -sL -o "$APPIMAGETOOL" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$APPIMAGETOOL"
fi

# ── Lay out the AppDir ───────────────────────────────────────────────────────
say "building AppDir at $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/omadvd" \
         "$APPDIR/usr/share/icons/hicolor/scalable/apps" \
         "$APPDIR/usr/share/applications"

install -m755 "$MPV_BIN"           "$APPDIR/usr/bin/mpv"
install -m755 "$ROOT/src/omadvd"   "$APPDIR/usr/bin/omadvd"
cp -r "$ROOT/src/lua" "$ROOT/src/conf" "$APPDIR/usr/share/omadvd/"
install -m755 "$HERE/AppRun"       "$APPDIR/AppRun"
install -m644 "$HERE/omadvd.desktop" "$APPDIR/omadvd.desktop"
install -m644 "$HERE/omadvd.desktop" "$APPDIR/usr/share/applications/omadvd.desktop"
install -m644 "$HERE/omadvd.svg"   "$APPDIR/omadvd.svg"
install -m644 "$HERE/omadvd.svg"   "$APPDIR/usr/share/icons/hicolor/scalable/apps/omadvd.svg"

# ── Walk the dependency graph ────────────────────────────────────────────────
# ldd is transitive, so one pass over mpv plus the hand-added libdvdcss covers
# everything; the loop below re-runs until nothing new appears anyway, which
# also catches deps of libdvdcss itself.
copy_deps() {
  local target=$1 line soname path base
  ldd "$target" 2>/dev/null | while read -r line; do
    soname=$(printf '%s' "$line" | awk '{print $1}')
    path=$(printf '%s' "$line" | awk '/=>/ {print $3}')
    [ -n "$path" ] && [ -f "$path" ] || continue
    base=$(basename "$path")
    is_excluded "$base" && continue
    [ -e "$APPDIR/usr/lib/$base" ] && continue
    cp -L "$path" "$APPDIR/usr/lib/$base"
    printf '    + %s\n' "$base"
  done
}

say "copying bundled libraries (host keeps the driver + display stack)"
cp -L "$CSS" "$APPDIR/usr/lib/libdvdcss.so.2"
echo "    + libdvdcss.so.2 (dlopen'd by libdvdread -- invisible to ldd)"

prev=0
for pass in 1 2 3 4 5; do
  copy_deps "$APPDIR/usr/bin/mpv"
  for so in "$APPDIR"/usr/lib/*.so*; do copy_deps "$so"; done
  now=$(find "$APPDIR/usr/lib" -type f | wc -l)
  [ "$now" = "$prev" ] && break
  prev=$now
done
say "bundled $(find "$APPDIR/usr/lib" -type f | wc -l) libraries, $(du -sh "$APPDIR/usr/lib" | cut -f1)"

# ── Sanity checks before we seal it ──────────────────────────────────────────
missing=$(env LD_LIBRARY_PATH="$APPDIR/usr/lib" ldd "$APPDIR/usr/bin/mpv" \
          | awk '/not found/ {print $1}' || true)
[ -z "$missing" ] || { echo "unresolved after bundling: $missing" >&2; exit 1; }
[ -e "$APPDIR/usr/lib/libdvdcss.so.2" ] || { echo "libdvdcss missing" >&2; exit 1; }
[ -e "$APPDIR/usr/share/omadvd/lua/omadvd.lua" ] || { echo "ui script missing" >&2; exit 1; }

# ── Seal ─────────────────────────────────────────────────────────────────────
say "packing $OUT"
rm -f "$OUT"
ARCH=x86_64 "$APPIMAGETOOL" --no-appstream "$APPDIR" "$OUT" >/dev/null 2>&1 \
  || ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUT"
chmod +x "$OUT"
say "done: $OUT ($(du -h "$OUT" | cut -f1))"
