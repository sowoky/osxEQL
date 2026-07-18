#!/bin/bash
# diag-resize.sh — instrumented launch to answer ONE question:
#
#   When the user toggles fullscreen<->windowed IN-GAME, which link in the chain
#   breaks the mouse?   EQ device reset -> DXGI ResizeBuffers -> DXMT swapchain
#   -> Wine virtual desktop (macdrv).
#
# Today the launcher pins all sizes at launch and declares mid-session changes
# "relaunch instead" (gotcha #4). That rule was inferred from window-DRAG
# observations, never from an instrumented fullscreen-toggle run. This harness
# captures every layer with timestamps so we can see whether a truly dynamic
# resize is achievable, and if not, exactly which link refuses.
#
# USAGE (on the Mac, from the repo root or anywhere):
#   engine/diag-resize.sh play      # full LaunchPad flow — log in, enter world,
#                                   # then: toggle fullscreen in Options > Display,
#                                   # move the mouse over UI, toggle back, quit.
#   engine/diag-resize.sh patchme   # direct eqgame (no auth) — quick sanity only
#   engine/diag-resize.sh report [dir]   # re-print the summary for a past run
#
# Output: ~/Library/Application Support/osxEQL/logs/diag-resize-<ts>/
#   wine.log            full wine output (+timestamp,+system,+macdrv,+display,+explorer)
#   ini-timeline.log    every eqclient.ini rewrite, timestamped, keys extracted
#   window-timeline.log on-screen bounds of the Wine windows (CGWindowList), 1 Hz
#   dbg.txt             EQ's own log, copied at exit
#   eqclient.before.ini / eqclient.after.ini
#   summary.txt         the analysis (also printed)
#
# Instrumentation notes:
#   - MTL_HUD_ENABLED=1 puts Apple's Metal HUD on the window: it shows the LIVE
#     drawable size. Watch it during the toggle — if the resolution line changes,
#     DXMT resized its surface; if it stays put, DXMT/EQ never resized.
#     Disable with OSXEQL_DIAG_NOHUD=1 if it obscures the test.
#   - One-shot like every launch path: NO kill/retry loops (hard rule). Watchers
#     are our own shell loops and die when wine exits; wineserver is never touched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"

[ "$(uname -s)" = "Darwin" ] || die "this harness drives the real launch path — run it on the Mac"

# ---- runtime: staged dev Wine, else the app bundle (kyle-mac has no staged Wine) ----
if [ ! -x "$WINE" ]; then
    APP_WINE_DIR="/Applications/osxEQL.app/Contents/Resources/Wine"
    [ -x "$APP_WINE_DIR/bin/wine" ] || die "no wine runtime: neither $WINE_DIR nor $APP_WINE_DIR"
    WINE_DIR="$APP_WINE_DIR"; WINE="$WINE_DIR/bin/wine"; WINESERVER="$WINE_DIR/bin/wineserver"
fi

# ---- prefix: same resolution order as the app (prefix/ then legacy prefix-cx/) ----
if [ ! -f "$WINEPREFIX/system.reg" ] && [ -f "$OSXEQL_HOME/prefix-cx/system.reg" ]; then
    export WINEPREFIX="$OSXEQL_HOME/prefix-cx"
    EQ_UNIXDIR="$WINEPREFIX/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends"
fi
[ -f "$WINEPREFIX/system.reg" ] || die "no prefix at $WINEPREFIX"
INI="$EQ_UNIXDIR/eqclient.ini"

MODE="${1:-play}"

# ---- report-only mode ------------------------------------------------------
latest_run(){ ls -dt "$LOGDIR"/diag-resize-* 2>/dev/null | head -1; }

summarize(){  # $1 = run dir
    local d="$1" s="$1/summary.txt"
    {
        echo "== osxEQL resize diagnosis — $(basename "$d") =="
        echo
        echo "-- EQ layer (dbg.txt): device resets + window sizes --"
        grep -aiE 'HandleResolutionChanged|InitDevice|Window (Width|Height)|windowed mode|fullscreen|resolution' \
            "$d/dbg.txt" 2>/dev/null | tail -40 || echo "(no dbg.txt captured)"
        echo
        echo "-- eqclient.ini rewrites during the session --"
        cat "$d/ini-timeline.log" 2>/dev/null || echo "(none)"
        echo
        echo "-- Wine layer: display-mode calls reaching win32u/macdrv --"
        grep -aiE 'ChangeDisplaySettings|SetCurrentDisplayMode|display_set|set_display|desktop.*(size|resize)|display_mode' \
            "$d/wine.log" 2>/dev/null | grep -av ':warn:' | tail -60 || echo "(none logged)"
        echo
        echo "-- DXGI/DXMT layer: swapchain resize activity --"
        grep -aiE 'resizebuffer|resize_buffer|swapchain.*(resize|size)|dxmt.*resiz|drawable.*(size|resiz)' \
            "$d/wine.log" 2>/dev/null | tail -40 || echo "(none logged)"
        echo
        echo "-- Host window bounds over time (what macOS actually showed) --"
        cat "$d/window-timeline.log" 2>/dev/null | tail -40 || echo "(none)"
        echo
        echo "== How to read this =="
        echo " A. dbg.txt shows a device reset at a NEW size after your toggle,"
        echo "    AND window-timeline shows the desktop window change size,"
        echo "    AND the Metal HUD resolution changed"
        echo "      -> the whole chain resizes; the desync is only the ini-vs-desktop"
        echo "         bookkeeping — a dynamic fix in the launcher is ON."
        echo " B. dbg.txt resets but window-timeline NEVER changes"
        echo "      -> Wine's virtual desktop refuses/ignores the mode change; the"
        echo "         fix targets macdrv/explorer (or resizing the desktop for it)."
        echo " C. wine.log shows no ChangeDisplaySettings at all after the toggle"
        echo "      -> EQ only rewrites the ini and re-inits internally; render size"
        echo "         is decided by DXMT's swapchain — look at the DXGI section/HUD."
        echo " D. Nothing anywhere reacted to the toggle"
        echo "      -> EQ defers the change to next restart; dynamic is a dead end,"
        echo "         and the right robust fix is guarding/healing (different plan)."
    } | tee "$s"
    echo
    echo "[osxEQL] full bundle: $d"
}

if [ "$MODE" = "report" ]; then
    d="${2:-$(latest_run)}"; [ -n "$d" ] && [ -d "$d" ] || die "no diag run found"
    summarize "$d"; exit 0
fi

[ -f "$EQ_UNIXDIR/eqgame.exe" ] || die "EQ not installed in prefix ($EQ_UNIXDIR)"

# ---- resolve size + pin ini exactly like the app (known-good starting state) ----
resolve_size(){
    local pin disp dw dh mode="auto"
    if [ -n "${OSXEQL_W:-}" ] && [ -n "${OSXEQL_H:-}" ]; then return 0; fi
    if [ -f "$OSXEQL_HOME/resolution" ]; then
        pin="$(tr -cd '0-9xa-z' < "$OSXEQL_HOME/resolution")"
        case "$pin" in
            max) mode="max" ;;
            [0-9]*x[0-9]*) OSXEQL_W="${pin%%x*}"; OSXEQL_H="${pin##*x}"; return 0 ;;
        esac
    fi
    disp="$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const d=$.CGMainDisplayID(); $.CGDisplayPixelsWide(d)+"x"+$.CGDisplayPixelsHigh(d)' 2>/dev/null)"
    dw="${disp%%x*}"; dh="${disp##*x}"
    case "${dw}${dh}" in *[!0-9]*|"") dw=1920; dh=1080 ;; esac
    if [ "$mode" = "max" ]; then OSXEQL_W="$dw"; OSXEQL_H="$dh"
    else OSXEQL_W=$((dw - 40)); OSXEQL_H=$((dh - 60)); fi
}
resolve_size

pin_ini(){  # same key set as app/launcher.sh fix_eqclient (gotcha #4: CRLF-safe python)
    [ -f "$INI" ] || return 0
    [ -f "$INI.osxeql-bak" ] || cp "$INI" "$INI.osxeql-bak"
    /usr/bin/python3 - "$INI" "$OSXEQL_W" "$OSXEQL_H" <<'PY'
import sys, re
p, w, h = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, "rb").read().decode("latin-1")
def setk(k, v, s):
    pat = re.compile(r'(?im)^(\s*' + re.escape(k) + r'\s*=).*?(\r?)$')
    return pat.sub(lambda m: m.group(1) + v + (m.group(2) or "\r"), s) if pat.search(s) else s
for k, v in (("Fullscreen", "0"), ("Width", w), ("Height", h),
             ("WindowedWidth", w), ("WindowedHeight", h)):
    s = setk(k, v, s)
open(p, "wb").write(s.encode("latin-1"))
PY
}
pin_ini

# ---- run dir ---------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
RUN="$LOGDIR/diag-resize-$TS"
mkdir -p "$RUN"
cp "$INI" "$RUN/eqclient.before.ini" 2>/dev/null || true

# ---- environment (mirrors app/launcher.sh; gotcha #2: NEVER export WINELOADER) ----
export PATH="$WINE_DIR/bin:$PATH"
export WINESERVER
export WINEDLLPATH="$WINE_DIR/lib/wine/x86_64-windows:$WINE_DIR/lib/wine/i386-windows"
export WINEDLLOVERRIDES="mscoree,mshtml="
export DYLD_FALLBACK_LIBRARY_PATH="$WINE_DIR/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
if [ -f "$WINE_DIR/lib/MoltenVK_icd.json" ]; then
    export VK_DRIVER_FILES="$WINE_DIR/lib/MoltenVK_icd.json"
    export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
fi
# The instrumentation itself:
#   +system   win32u sysparams — NtUserChangeDisplaySettings & friends
#   +display  winemac.drv display.c — mode-set on the mac side
#   +macdrv   winemac.drv general (window/surface plumbing)
#   +explorer the virtual desktop window itself
export WINEDEBUG="fixme-all,+timestamp,+system,+display,+macdrv,+explorer"
export DXMT_LOG_LEVEL="${DXMT_LOG_LEVEL:-debug}"      # DXMT swapchain chatter (if honored)
[ "${OSXEQL_DIAG_NOHUD:-0}" = 1 ] || export MTL_HUD_ENABLED=1   # live drawable size on screen
clean_stale_winetemp

# ---- watchers (our own shells; they exit when wine does) --------------------
ini_keys(){ /usr/bin/python3 - "$INI" <<'PY'
import sys, re
s = open(sys.argv[1], "rb").read().decode("latin-1")
out = []
for k in ("Fullscreen", "Width", "Height", "WindowedWidth", "WindowedHeight"):
    m = re.search(r'(?im)^\s*' + k + r'\s*=\s*(\S*)', s)
    out.append(f"{k}={m.group(1) if m else '?'}")
print(" ".join(out))
PY
}

watch_ini(){
    local last cur
    last="$(stat -f %m "$INI" 2>/dev/null || echo 0)"
    echo "$(date +%H:%M:%S) BASELINE $(ini_keys)" >> "$RUN/ini-timeline.log"
    while :; do
        sleep 0.5
        cur="$(stat -f %m "$INI" 2>/dev/null || echo 0)"
        if [ "$cur" != "$last" ]; then
            last="$cur"
            echo "$(date +%H:%M:%S) REWRITE  $(ini_keys)" >> "$RUN/ini-timeline.log"
        fi
    done
}

watch_windows(){
    local last="" cur
    while :; do
        cur="$(osascript -l JavaScript -e '
            ObjC.import("CoreGraphics");
            const a = ObjC.deepUnwrap($.CFBridgingRelease(
                $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
            const rx = /wine|eqgame|launchpad|explorer|osxeql/i;
            a.filter(w => rx.test(String(w.kCGWindowOwnerName||"")) || rx.test(String(w.kCGWindowName||"")))
             .map(w => `${w.kCGWindowOwnerName}|${w.kCGWindowName||""}|` +
                       `${w.kCGWindowBounds.X},${w.kCGWindowBounds.Y} ` +
                       `${w.kCGWindowBounds.Width}x${w.kCGWindowBounds.Height}`)
             .join("\n")' 2>/dev/null)"
        if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
            last="$cur"
            printf '%s\n%s\n' "$(date +%H:%M:%S) ----" "$cur" >> "$RUN/window-timeline.log"
        fi
        sleep 1
    done
}

watch_ini & INI_PID=$!
watch_windows & WIN_PID=$!

# ---- launch (same shape as the app / 04-launch.sh) --------------------------
caffeinate -dimsu -w $$ &
cd "$EQ_UNIXDIR" || die "cd to EQ dir failed"

log "diag run: $RUN"
log "desktop ${OSXEQL_W}x${OSXEQL_H}; Metal HUD $([ "${MTL_HUD_ENABLED:-0}" = 1 ] && echo ON || echo off)"
log "TEST SCRIPT: get in game -> note the HUD resolution -> Options > Display ->"
log "  toggle fullscreen -> move mouse over UI, note where clicks land + HUD res ->"
log "  toggle back to windowed -> same checks -> quit normally."

if [ "$MODE" = "patchme" ]; then
    "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" \
        "$EQ_WINDIR\\eqgame.exe" patchme >"$RUN/wine.log" 2>&1
else
    "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" \
        "$EQ_WINDIR\\LaunchPad.exe" >"$RUN/wine.log" 2>&1
fi

# ---- collect + analyze ------------------------------------------------------
kill "$INI_PID" "$WIN_PID" 2>/dev/null; wait "$INI_PID" "$WIN_PID" 2>/dev/null
cp "$INI" "$RUN/eqclient.after.ini" 2>/dev/null || true
cp "$EQ_UNIXDIR/Logs/dbg.txt" "$RUN/dbg.txt" 2>/dev/null || true

summarize "$RUN"
