#!/bin/bash
# Install / switch the D3D11->Metal graphics backend in the staged Wine.
#   usage: 03-install-backend.sh [dxmt|wined3d]   (default: dxmt)
#
# DXMT ships "builtin" DLLs that replace wined3d's d3d11/d3d10core/dxgi in the
# Wine library tree, plus winemetal.dll and the native winemetal.so bridge.
# We back up the originals so `wined3d` can restore them (backend swapping).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
have_wine || die "wine not staged — run 01 first"
BACKEND="${1:-dxmt}"

# Locate the wine lib tree's per-arch dirs.
win_dirs=( "$WINE_DIR"/lib/wine/*-windows )
unix_dir="$WINE_DIR/lib/wine/x86_64-unix"
[ -d "${win_dirs[0]}" ] || die "can't find wine lib tree under $WINE_DIR/lib/wine"

D3D_DLLS=(d3d11.dll d3d10core.dll dxgi.dll)

backup_originals() {  # back up wined3d versions once
    for d in "${win_dirs[@]}"; do
        for f in "${D3D_DLLS[@]}"; do
            [ -f "$d/$f" ] && [ ! -f "$d/$f.wined3d.bak" ] && cp -p "$d/$f" "$d/$f.wined3d.bak"
        done
    done
}

install_dxmt() {
    local src="$BACKENDS/dxmt-${DXMT_VERSION}"
    [ -d "$src" ] || die "dxmt not staged — run 01 first"
    backup_originals
    local n=0
    for d in "${win_dirs[@]}"; do
        local arch; arch="$(basename "$d")"          # x86_64-windows | i386-windows
        local sd="$src/$arch"
        [ -d "$sd" ] || { warn "dxmt has no $arch payload, skipping"; continue; }
        for f in "$sd"/*.dll; do cp -f "$f" "$d/"; n=$((n+1)); done
    done
    # native Metal bridge
    [ -f "$src/x86_64-unix/winemetal.so" ] && cp -f "$src/x86_64-unix/winemetal.so" "$unix_dir/"
    # winemetal.dll ALSO required in the prefix system32/syswow64 — per the DXMT
    # guide, the import resolver needs it there, not only in the wine builtin tree.
    if have_prefix; then
        local sys32="$WINEPREFIX/drive_c/windows/system32" syswow="$WINEPREFIX/drive_c/windows/syswow64"
        [ -f "$src/x86_64-windows/winemetal.dll" ] && cp -f "$src/x86_64-windows/winemetal.dll" "$sys32/" 2>/dev/null && log "  winemetal.dll -> system32"
        [ -f "$src/i386-windows/winemetal.dll" ] && [ -d "$syswow" ] && cp -f "$src/i386-windows/winemetal.dll" "$syswow/" 2>/dev/null
    fi
    echo "dxmt ${DXMT_VERSION}" > "$OSXEQL_HOME/backend.active"
    log "DXMT ${DXMT_VERSION} installed ($n DLLs across ${#win_dirs[@]} arch trees + winemetal.so)"
}

restore_wined3d() {
    local n=0
    for d in "${win_dirs[@]}"; do
        for f in "${D3D_DLLS[@]}"; do
            [ -f "$d/$f.wined3d.bak" ] && { cp -f "$d/$f.wined3d.bak" "$d/$f"; n=$((n+1)); }
        done
    done
    echo "wined3d" > "$OSXEQL_HOME/backend.active"
    log "restored wined3d ($n DLLs)"
}

case "$BACKEND" in
    dxmt)    install_dxmt ;;
    wined3d) restore_wined3d ;;
    *)       die "unknown backend '$BACKEND' (dxmt|wined3d)" ;;
esac
