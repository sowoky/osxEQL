#!/bin/bash
# Shared plumbing for rebuilding ONE Wine unix driver (winemac.so, winecoreaudio.so)
# from the pinned CodeWeavers CrossOver source and swapping it into the runtime(s)
# in place — used by engine/overlay.sh and engine/audiofix.sh. Sourced after lib.sh.
#
# Minutes, not the full 30-60 min engine/build-wine.sh: one shared, configured build
# tree ($BUILD) makes just the requested .so. Nothing prebuilt is downloaded.
# Requires: Xcode command-line tools, and bison >= 3 (brew install bison).

CX_VERSION="${OSXEQL_CX_VERSION:-26.2.0}"      # must match engine/build-wine.sh
WS="$HOME/osxeql-wine-build"                    # shared with build-wine.sh (tarball cache)
TARBALL="$WS/crossover-sources-${CX_VERSION}.tar.gz"
WORK="$WS/overlay-${CX_VERSION//./}"
WINESRC="$WORK/sources/wine"
BUILD="$WORK/build-winemac"                     # name kept: existing trees stay reusable
# The installed app: osxEQL-Buddy.app (1.0+), or a pre-1.0 osxEQL.app.
if [ -z "${OSXEQL_APP:-}" ]; then
    for OSXEQL_APP in /Applications/osxEQL-Buddy.app /Applications/osxEQL.app; do
        [ -d "$OSXEQL_APP" ] && break
    done
fi
APP="$OSXEQL_APP"
UNIXLIB="lib/wine/x86_64-unix"

# Unique real paths of the runtimes to patch: the engine's and the app's (once if one
# is a symlink to the other).
runtimes() {
    local seen="" d r
    for d in "$WINE_DIR" "$APP/Contents/Resources/Wine"; do
        [ -f "$d/$UNIXLIB/winemac.so" ] || continue
        r="$(cd "$d" && pwd -P)"
        case "|$seen|" in *"|$r|"*) continue ;; esac
        seen="$seen|$r"
        printf '%s\n' "$r"
    done
}

# Marker = SHA-256 of the exact patched file we installed (a later swap/revert
# invalidates it). $1 = .so path, $2 = marker suffix.
marker_ok() {
    [ -f "$1.$2" ] || return 1
    [ "$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1)" = "$(tr -cd '0-9a-f' < "$1.$2")" ]
}

# Re-sign the enclosing .app, if the runtime lives inside one.
resign_app() {
    local rt="$1" app
    case "$rt" in */Contents/Resources/Wine) app="${rt%/Contents/Resources/Wine}" ;; *) return 0 ;; esac
    log "re-signing $app (ad-hoc)"
    codesign --force --deep --sign - "$app" >/dev/null 2>&1 || warn "codesign of $app failed — it may refuse to launch"
}

# $1 runtime, $2 built .so, $3 .so name, $4 marker suffix
install_driver() {
    local so="$1/$UNIXLIB/$3"
    [ -f "$so.osxeql-orig" ] || cp "$so" "$so.osxeql-orig"    # keep the very first original
    cp "$2" "$so" || die "could not write $so"
    codesign --force --sign - "$so" >/dev/null 2>&1 || true
    shasum -a 256 "$so" | cut -d' ' -f1 > "$so.$4"
    resign_app "$1"
    log "patched: $so"
}

# $1 runtime, $2 .so name, $3 marker suffix
revert_driver() {
    local so="$1/$UNIXLIB/$2"
    [ -f "$so.osxeql-orig" ] || { log "no backup of $2 in $1 — leaving it"; return 0; }
    cp "$so.osxeql-orig" "$so" && codesign --force --sign - "$so" >/dev/null 2>&1
    rm -f "$so.$3"
    resign_app "$1"
    log "restored: $so"
}

game_running() { pgrep -f 'eqgame|LaunchPad|EQBuddy\.exe' >/dev/null; }

find_bison() {
    local b
    for b in /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin; do
        [ -x "$b/bison" ] && { printf '%s\n' "$b"; return 0; }
    done
    return 1
}

# Toolchain + extracted source + configured tree. Sets BISONDIR.
prepare_tree() {
    xcode-select -p >/dev/null 2>&1 || die "Xcode command-line tools missing — run: xcode-select --install"
    BISONDIR="$(find_bison)" || die "bison >= 3 not found — run: brew install bison"
    mkdir -p "$WS" "$WORK"
    if [ ! -f "$WINESRC/configure" ]; then
        if [ ! -s "$TARBALL" ]; then
            log "downloading CrossOver ${CX_VERSION} source (CodeWeavers' LGPL drop)…"
            curl -fL --retry 3 --progress-bar -o "$TARBALL.part" \
                "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz" \
                && mv "$TARBALL.part" "$TARBALL" || { rm -f "$TARBALL.part"; die "source download failed"; }
        fi
        log "extracting sources/wine…"
        tar xzf "$TARBALL" -C "$WORK" sources/wine || die "extract failed"
    fi
    if [ ! -f "$BUILD/Makefile" ]; then
        log "configuring (unix drivers only)…"
        mkdir -p "$BUILD"
        ( cd "$BUILD" && PATH="$BISONDIR:$PATH" CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
            "$WINESRC/configure" --host=x86_64-apple-darwin --without-mingw \
            --enable-archs=none --disable-tests \
            --without-alsa --without-capi --without-cups --without-dbus --without-ffmpeg \
            --without-fontconfig --without-freetype --without-gphoto --without-gnutls \
            --without-gssapi --without-gstreamer --without-hwloc --without-inotify --without-krb5 \
            --without-netapi --without-opencl --without-oss --without-pcap --without-pcsclite \
            --without-pulse --without-sane --without-sdl --without-udev --without-unwind \
            --without-usb --without-v4l2 --without-vulkan --without-wayland >"$LOGDIR/overlay-configure.log" 2>&1 ) \
            || die "configure failed — see $LOGDIR/overlay-configure.log"
    fi
}

# make one unix lib: $1 = make target (e.g. dlls/winemac.drv/winemac.so),
# $2 = the runtime's current winemac.so (its Vulkan soname is reused), $3 = log file.
make_driver() {
    local target="$1" ref="$2" logf="$3" vk
    # Keep the Vulkan library name the shipped winemac.so was built with (the runtime's
    # own build had Vulkan; this drivers-only configure doesn't, so it is passed in).
    vk="$(strings "$ref" 2>/dev/null | grep -m1 -E '^lib(MoltenVK|vulkan)[A-Za-z0-9._-]*\.dylib$')"
    vk="${vk:-libMoltenVK.dylib}"
    log "building $(basename "$target") (Vulkan soname: $vk)…"
    # Doubled backslashes are load-bearing: make runs each recipe through /bin/sh.
    ( cd "$BUILD" && PATH="$BISONDIR:$PATH" \
        make "$target" -j"$(sysctl -n hw.ncpu)" \
        "CFLAGS=-g -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -DSONAME_LIBVULKAN=\\\"$vk\\\"" \
        >"$logf" 2>&1 ) || die "build failed — see $logf"
    [ -f "$BUILD/$target" ] || die "build produced no $(basename "$target")"
}
