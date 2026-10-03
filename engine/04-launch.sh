#!/bin/bash
# Launch EQL: starts the Daybreak LaunchPad (which authenticates, then spawns the
# 64-bit eqgame.exe). Runs in a Wine virtual desktop to avoid the launcher's
# splash-window deadlock. One-shot — NO kill/retry loops (hard rule).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/eqbuddy.sh"
EQBUDDY_FOCUS_SRC="$HERE/tools/eqbuddy-focus.swift"
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

# Virtual-desktop size, resolved exactly like the .app (resolve_size in lib.sh):
# OSXEQL_W/OSXEQL_H > `osxeql res` pin > exactly the current display. It used to
# default to a fixed 1280x960, which left the mouse dead outside 1280x960 as soon
# as EQ's own sizes differed (gotcha #4). For a headless `patchme` check, set
# OSXEQL_W=1280 OSXEQL_H=960 explicitly.
resolve_size
log "game window: ${OSXEQL_W}x${OSXEQL_H} (osxeql res to change)"
pin_eqclient "$OSXEQL_W" "$OSXEQL_H" "$OSXEQL_FULLDISPLAY"
cd "$EQ_UNIXDIR" || die "cd to EQ dir failed"
# EQBuddy Evolved companion, if installed + enabled (osxeql eqbuddy) — same desktop.
# Its own log: the exec below truncates $launchlog, which used to erase these lines.
echo "==== $(date) ====" >> "$LOGDIR/eqbuddy.log"
eqbuddy_update_and_launch "$OSXEQL_W" "$OSXEQL_H" "$LOGDIR/eqbuddy.log"   # background
exec "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" \
    "$EQ_WINDIR\\LaunchPad.exe" >"$launchlog" 2>&1
