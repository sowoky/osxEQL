#!/bin/bash
# Launch EQL: starts the Daybreak LaunchPad (which authenticates, then spawns the
# 64-bit eqgame.exe). Runs in a Wine virtual desktop to avoid the launcher's
# splash-window deadlock. One-shot — NO kill/retry loops (hard rule).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"
have_wine   || die "wine not staged"
have_prefix || die "no prefix — run setup first"
have_eq     || die "EQL not installed in prefix ($EQ_UNIXDIR). Run: osxeql install  (or import-client)"
wine_env

backend="$(cat "$OSXEQL_HOME/backend.active" 2>/dev/null || echo '?')"
ts="$(date +%Y%m%d-%H%M%S)"
launchlog="$LOGDIR/launch-$ts.log"
log "launching EQL (backend: $backend)  log: $launchlog"
log "game's own debug log: $EQ_UNIXDIR/Logs/dbg.txt"

# keep the Mac awake while the game runs
caffeinate -dimsu -w $$ &

# Virtual-desktop size. Must match eqclient.ini WindowedWidth/Height or the
# mouse maps to the wrong pixels (gotcha #4). Default 1280x960 for headless
# `patchme` verification; override with OSXEQL_W/OSXEQL_H (the .app uses 3420x1505).
OSXEQL_W="${OSXEQL_W:-1280}"
OSXEQL_H="${OSXEQL_H:-960}"
cd "$EQ_UNIXDIR" || die "cd to EQ dir failed"
exec "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" \
    "$EQ_WINDIR\\LaunchPad.exe" >"$launchlog" 2>&1
