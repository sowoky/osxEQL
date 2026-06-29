#!/bin/bash
# Stage the open-source runtime: verify a from-source Wine is present, then extract
# DXMT into $BACKENDS (downloading DXMT if the cache is empty). Idempotent.
# Wine is built by engine/build-wine.sh (or bundled inside osxEQL.app) — it is NOT
# downloaded as a prebuilt: Gcenx/upstream prebuilts lack macdrv_functions and
# cannot create a Metal view (gotcha #1).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"

fetch() {  # url dest
    local url="$1" dest="$2"
    [ -s "$dest" ] && { log "cached: $(basename "$dest")"; return; }
    log "downloading $(basename "$dest") ..."
    curl -fL --retry 3 -o "$dest" "$url" || die "download failed: $url"
}

# --- Wine (built from source; never downloaded here) -----------------------
stage_wine() {
    if have_wine; then log "wine present ($WINE_DIR): $("$WINE" --version 2>/dev/null)"; return; fi
    die "no Wine runtime at $WINE_DIR.
Build it from CodeWeavers' published LGPL source:

    engine/build-wine.sh        # ~30-60 min; stages to $OSXEQL_HOME/Wine.cxbuild

then verify DXMT render and move that tree to $WINE_DIR. (Or just run osxEQL.app,
which ships the runtime inside the bundle.)"
}

# --- DXMT ------------------------------------------------------------------
stage_dxmt() {
    local tgz="$CACHE/dxmt-${DXMT_VERSION}-builtin.tar.gz"
    fetch "$DXMT_URL" "$tgz"
    local dest="$BACKENDS/dxmt-${DXMT_VERSION}"
    [ -d "$dest" ] && [ -z "${FORCE:-}" ] && { log "dxmt already extracted"; return; }
    rm -rf "$dest"; mkdir -p "$dest"
    tar xzf "$tgz" -C "$dest" --strip-components=1 || die "dxmt extract failed"
    xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
    log "dxmt staged: $dest"
}

stage_wine
stage_dxmt
log "runtime staged."
