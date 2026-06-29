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

have_wine()   { [ -x "$WINE" ]; }
have_prefix() { [ -f "$WINEPREFIX/system.reg" ]; }
have_eq()     { [ -f "$EQ_UNIXDIR/eqgame.exe" ]; }
