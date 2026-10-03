#!/bin/bash
# osxEQL engine — shared config + helpers.
# Sourced by every engine script. Open-source stack: Wine built from CodeWeavers'
# published LGPL source (engine/build-wine.sh) + DXMT. No proprietary D3DMetal.
# NOTE: prebuilt Gcenx Wine does NOT work — it lacks the macdrv_functions symbol
# DXMT needs (gotcha #1). The Wine runtime comes from build-wine.sh (or is bundled
# inside osxEQL.app); it is never downloaded as a prebuilt here.
set -uo pipefail

# ---- Versions (pinned; bump deliberately) ---------------------------------
# Wine is compiled from CrossOver source — version pinned in engine/build-wine.sh
# (OSXEQL_CX_VERSION, currently 26.2.0).
DXMT_VERSION="${OSXEQL_DXMT_VERSION:-v0.80}"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/${DXMT_VERSION}/dxmt-${DXMT_VERSION}-builtin.tar.gz"

# Optional DXVK fallback backend (D3D11->Vulkan->MoltenVK)
DXVK_VERSION="${OSXEQL_DXVK_VERSION:-v1.10.3}"

# ---- Paths ----------------------------------------------------------------
OSXEQL_HOME="${OSXEQL_HOME:-$HOME/Library/Application Support/osxEQL}"
WINE_DIR="$OSXEQL_HOME/Wine"            # staged Gcenx wine (contains bin/, lib/)
export WINEPREFIX="${WINEPREFIX:-$OSXEQL_HOME/prefix}"
CACHE="$OSXEQL_HOME/cache"
BACKENDS="$OSXEQL_HOME/backends"        # extracted dxmt/dxvk payloads
LOGDIR="$OSXEQL_HOME/logs"

WINE="$WINE_DIR/bin/wine"
WINESERVER="$WINE_DIR/bin/wineserver"

# EQL install location inside the prefix (matches Daybreak's own layout)
EQ_WINDIR='C:\users\Public\Daybreak Game Company\Installed Games\EverQuest Legends'
EQ_UNIXDIR="$WINEPREFIX/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends"

mkdir -p "$OSXEQL_HOME" "$CACHE" "$BACKENDS" "$LOGDIR" 2>/dev/null || true

# ---- Helpers --------------------------------------------------------------
log()  { printf '\033[1;36m[osxEQL]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[osxEQL] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[osxEQL] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Remove stale wine loader temp dirs whose ntdll.so symlink is dangling.
# To exec any child process, wine's macOS loader builds a temp dir
# ($TMPDIR/winetemp-<inode>-<size>-<mtime>-...) of stub loaders plus an
# ntdll.so SYMLINK to the runtime's real ntdll.so. The dir name is
# DETERMINISTIC (keyed to the loader binary) and REUSED across launches. If the
# Wine runtime dir was moved/renamed/rebuilt (e.g. Wine.cxbuild -> Wine) or
# macOS partially purged $TMPDIR, the cached dir's ntdll.so symlink dangles and
# EVERY child exec dies with "could not load ntdll.so" — the .app then silently
# does nothing (no window, no dialog). Removing the broken dir makes wine
# regenerate it fresh against the current runtime path. Only dangling-symlink
# dirs are touched; a LIVE wine session's winetemp has a valid symlink, so this
# is safe even mid-session. (Receipt: docs/JOURNEY.md "winetemp ntdll.so".)
clean_stale_winetemp() {
    local d
    for d in "${TMPDIR:-/tmp}"/winetemp-*; do
        [ -d "$d" ] || continue
        if [ -L "$d/ntdll.so" ] && [ ! -e "$d/ntdll.so" ]; then
            rm -rf "$d" 2>/dev/null || true
        fi
    done
}

# Set up the wine runtime environment for a command.
wine_env() {
    export WINEPREFIX
    export PATH="$WINE_DIR/bin:$PATH"
    export WINEDEBUG="${WINEDEBUG:--all}"
    # mscoree/mshtml disabled = no mono/gecko install nag
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
    clean_stale_winetemp
}

# ---- game window size (gotcha #4) — same rules as the .app's launcher ------
# The Wine virtual desktop AND the eqclient.ini size keys must agree, or the
# mouse only reaches part of the window. Precedence, resolved at every launch:
#   1. OSXEQL_W/OSXEQL_H env vars (e.g. 1280x960 for a headless `patchme` check)
#   2. $OSXEQL_HOME/resolution — "WxH" pin or "auto" (osxeql res)
#   3. default ("max"): exactly the current main display, in points.
# Why max by default: EQ's in-game fullscreen asks Wine for a display mode of
# Width x Height. A virtual desktop only offers its own size plus smaller
# standard modes, so any odd size (e.g. display minus chrome) makes EQ fall back
# to a low mode (1280x960): the desktop shrinks, the mouse is clipped to it and
# EQ rewrites Width/Height. At exactly the display size the mode always exists,
# fullscreen and windowed are the same size, and the mouse maps 1:1.
# Sets OSXEQL_FULLDISPLAY=1 when the size IS the display (see pin_eqclient).
_display_size() {
    local disp
    disp="$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const d=$.CGMainDisplayID(); $.CGDisplayPixelsWide(d)+"x"+$.CGDisplayPixelsHigh(d)' 2>/dev/null)"
    DISP_W="${disp%%x*}"; DISP_H="${disp##*x}"
    case "${DISP_W}${DISP_H}" in *[!0-9]*|"") DISP_W=1920; DISP_H=1080 ;; esac
}
resolve_size() {
    local pin="" mode=max
    OSXEQL_FULLDISPLAY=0
    [ -f "$OSXEQL_HOME/resolution" ] && pin="$(tr -cd '0-9xa-z' < "$OSXEQL_HOME/resolution")"
    if [ -n "${OSXEQL_W:-}" ] && [ -n "${OSXEQL_H:-}" ]; then
        mode=env
    else
        case "$pin" in
            auto) mode=auto ;;
            [0-9]*x[0-9]*) mode=pin; OSXEQL_W="${pin%%x*}"; OSXEQL_H="${pin##*x}" ;;
        esac
    fi
    _display_size
    case "$mode" in
        max)  OSXEQL_W="$DISP_W"; OSXEQL_H="$DISP_H" ;;
        auto) OSXEQL_W=$((DISP_W - 40)); OSXEQL_H=$((DISP_H - 60)) ;;
    esac
    [ "$OSXEQL_W" = "$DISP_W" ] && [ "$OSXEQL_H" = "$DISP_H" ] && OSXEQL_FULLDISPLAY=1
    return 0
}

# Pin eqclient.ini (CRLF, latin-1) to the virtual-desktop size: windowed AND
# in-game-fullscreen keys. $3=1 (size == display): the player's Fullscreen choice
# is kept — both modes are the same size then. Otherwise Fullscreen=0 is forced,
# since a fullscreen request at a non-display size is what triggers the low-mode
# fallback. Backup once to eqclient.ini.osxeql-bak.
pin_eqclient() {
    local ini="$EQ_UNIXDIR/eqclient.ini"
    [ -f "$ini" ] || return 0
    [ -f "$ini.osxeql-bak" ] || cp "$ini" "$ini.osxeql-bak"
    /usr/bin/python3 - "$ini" "$1" "$2" "${3:-0}" <<'PY'
import sys, re
p, w, h, fulldisplay = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
s = open(p, "rb").read().decode("latin-1")
def setk(k, v, s):
    pat = re.compile(r'(?im)^(\s*' + re.escape(k) + r'\s*=).*?(\r?)$')
    return pat.sub(lambda m: m.group(1) + v + (m.group(2) or "\r"), s) if pat.search(s) else s
keys = [("Width", w), ("Height", h), ("WindowedWidth", w), ("WindowedHeight", h)]
if not fulldisplay:
    keys.insert(0, ("Fullscreen", "0"))
for k, v in keys:
    s = setk(k, v, s)
open(p, "wb").write(s.encode("latin-1"))
PY
}

# True if the driver $1 is the patched build engine/overlay.sh (marker suffix
# osxeql-overlay, the default) or engine/audiofix.sh (osxeql-audiofix) installed:
# its marker holds the hash of exactly this file (a later swap/revert invalidates it).
overlay_marker_ok() {
    local m="$1.${2:-osxeql-overlay}"
    [ -f "$m" ] || return 1
    [ "$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1)" = "$(tr -cd '0-9a-f' < "$m")" ]
}

have_wine()   { [ -x "$WINE" ]; }
have_prefix() { [ -f "$WINEPREFIX/system.reg" ]; }
have_eq()     { [ -f "$EQ_UNIXDIR/eqgame.exe" ]; }
