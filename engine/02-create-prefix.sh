#!/bin/bash
# Create a clean Wine prefix for EQL (win10, 64-bit). Idempotent.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
have_wine || die "wine not staged — run 01-stage-runtime.sh first"
wine_env

if have_prefix && [ -z "${FORCE:-}" ]; then
    log "prefix already exists: $WINEPREFIX"
    exit 0
fi

log "creating prefix at $WINEPREFIX (this runs wineboot, ~30-60s) ..."
export WINEARCH=win64
"$WINE" wineboot --init >"$LOGDIR/wineboot.log" 2>&1 || die "wineboot failed (see $LOGDIR/wineboot.log)"
"$WINESERVER" -w   # wait for the prefix to settle
# Wine 11 defaults to a Windows 10 identity, which is what EQL expects. Disable
# the crash dialog so a CEF child crash in the launcher can't wedge a modal.
"$WINE" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1 || true
"$WINESERVER" -w
have_prefix || die "prefix creation failed"
log "prefix ready."
