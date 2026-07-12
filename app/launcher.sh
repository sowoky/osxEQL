#!/bin/bash
# osxEQL — run EverQuest Legends on Apple Silicon with open-source Wine + DXMT.
#
# This is the app bundle's entry point (becomes Contents/MacOS/osxEQL). The Wine
# runtime (with DXMT baked in) is EMBEDDED in this bundle under Contents/Resources/Wine,
# so the app is self-contained and relocatable. The game client + wine prefix live
# OUTSIDE the app in ~/Library/Application Support/osxEQL (they persist across updates
# and must not bloat the .app).
#
# Two modes:
#  - INSTALL (no eqgame.exe yet): a native setup window (Resources/osxeql-progress)
#    stays up from launch, narrates every step, and the script SUPERVISES LaunchPad —
#    it pre-fixes Daybreak's Path="C:" registration bug, tails LaunchPad's own logs
#    for phase/progress, notifies when the login screen is ready, and self-heals +
#    relaunches if the launcher dies mid-install. One click → login screen.
#  - PLAY (game installed): straight to LaunchPad, no window (unchanged fast path).
set -u
trap '' PIPE

# ---- locate the embedded runtime ------------------------------------------
SELF="$(cd "$(dirname "$0")" && pwd)"                 # .../Contents/MacOS
RES="$(cd "$SELF/../Resources" && pwd)"
WINE_DIR="$RES/Wine"
WINE="$WINE_DIR/bin/wine"

OSXEQL_HOME="$HOME/Library/Application Support/osxEQL"
mkdir -p "$OSXEQL_HOME/logs"
LOG="$OSXEQL_HOME/logs/app-launch.log"

# Prefix: a fresh install uses ~/…/osxEQL/prefix. Back-compat: if a dev/older
# "prefix-cx" exists and there's no clean "prefix" yet, use it (so an existing
# install keeps working without a 7 GB re-download).
export WINEPREFIX="$OSXEQL_HOME/prefix"
if [ ! -f "$WINEPREFIX/system.reg" ] && [ -f "$OSXEQL_HOME/prefix-cx/system.reg" ]; then
    export WINEPREFIX="$OSXEQL_HOME/prefix-cx"
fi

export WINESERVER="$WINE_DIR/bin/wineserver"
export WINEDLLPATH="$WINE_DIR/lib/wine/x86_64-windows:$WINE_DIR/lib/wine/i386-windows"
# fixme-all (not -all): keep err:-class lines in app-launch.log — "-all" gave
# completely empty logs on user machines and made issue #2 an afternoon to debug.
export WINEDEBUG="fixme-all"
export WINEDLLOVERRIDES="mscoree,mshtml="
export DYLD_FALLBACK_LIBRARY_PATH="$WINE_DIR/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
# Vulkan: use the bundled MoltenVK via the bundled ICD json (relative path).
# Without a driver, LaunchPad's CEF UI can crash on Vulkan init on Macs with no
# Intel Homebrew (issue #2). Guarded so dev trees without the json keep the
# system ICD search.
if [ -f "$WINE_DIR/lib/MoltenVK_icd.json" ]; then
    export VK_DRIVER_FILES="$WINE_DIR/lib/MoltenVK_icd.json"
    export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
fi
# NEVER export WINELOADER — it makes wine copy the loader to a temp dir for child
# processes which then fail "could not load ntdll.so" (project gotcha #2).

GAME_WINDIR='C:\users\Public\Daybreak Game Company\Installed Games\EverQuest Legends'
GAME_DIR="$WINEPREFIX/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends"
GAME_LP="$GAME_DIR/LaunchPad.exe"
BOOT_LP="$WINEPREFIX/drive_c/LaunchPad.exe"           # where EQLegends_setup.exe /S lands it
BOOT_WINPATH='C:\LaunchPad.exe'
MISPLACED_DIR="$WINEPREFIX/drive_c/users/Public/Daybreak Game Company/Installed Games/C:"
LP_LOGS="$GAME_DIR/LaunchPad.libs/Logs"
EQL_URL="https://www.everquest.com/"

# ---- window size (project gotcha #4) --------------------------------------
# The Wine virtual desktop AND eqclient.ini's sizes MUST agree or mouse input
# is offset. Size is resolved fresh at every launch so switching between the
# ultrawide and the built-in display just works. Precedence:
#   1. OSXEQL_W/OSXEQL_H env vars
#   2. ~/Library/Application Support/osxEQL/resolution — "WxH" pin, "auto", or "max"
#   3. auto (default): current main display minus window chrome (menu+title bar)
resolve_size(){
    local mode="auto" pin disp dw dh
    if [ -n "${OSXEQL_W:-}" ] && [ -n "${OSXEQL_H:-}" ]; then return 0; fi
    if [ -f "$OSXEQL_HOME/resolution" ]; then
        pin="$(tr -cd '0-9xa-z' < "$OSXEQL_HOME/resolution")"
        case "$pin" in
            max)      mode="max" ;;
            [0-9]*x[0-9]*) OSXEQL_W="${pin%%x*}"; OSXEQL_H="${pin##*x}"; return 0 ;;
        esac
    fi
    # main-display size in points via CoreGraphics — fast, no permission prompts
    disp="$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const d=$.CGMainDisplayID(); $.CGDisplayPixelsWide(d)+"x"+$.CGDisplayPixelsHigh(d)' 2>/dev/null)"
    dw="${disp%%x*}"; dh="${disp##*x}"
    case "${dw}${dh}" in *[!0-9]*|"") dw=1920; dh=1080 ;; esac
    if [ "$mode" = "max" ]; then
        OSXEQL_W="$dw"; OSXEQL_H="$dh"
    else
        OSXEQL_W=$((dw - 40)); OSXEQL_H=$((dh - 60))
    fi
}
resolve_size

osa(){ /usr/bin/osascript "$@" 2>/dev/null; }
alert(){ osa -e "display alert \"osxEQL\" message \"$1\" as critical"; }

# ---- setup window (install mode only) --------------------------------------
# Resources/osxeql-progress shows a native window; we feed it one command per
# line on fd 9 (PHASE/DETAIL/PROGRESS/INDET/LOG/READY/DONE/FAIL/QUIT).
PROGRESS_ON=""
progress(){ [ -n "$PROGRESS_ON" ] && printf '%s\n' "$*" >&9 2>/dev/null || true; }
start_progress_window(){
    [ -x "$RES/osxeql-progress" ] || return 0
    local fifo="${TMPDIR:-/tmp}/osxeql-progress-$$.fifo"
    rm -f "$fifo"
    mkfifo "$fifo" 2>/dev/null || return 0
    "$RES/osxeql-progress" < "$fifo" &
    exec 9>"$fifo"
    rm -f "$fifo"
    PROGRESS_ON=1
}

# ---- sanity: runtime present ----------------------------------------------
if [ ! -x "$WINE" ]; then
    alert "This osxEQL.app is missing its Wine runtime (Contents/Resources/Wine). Re-download the full app from GitHub."
    exit 1
fi

# ---- self-heal stale wine loader temp dirs (project gotcha) ----------------
for _wt in "${TMPDIR:-/tmp}"/winetemp-*; do
    [ -L "$_wt/ntdll.so" ] && [ ! -e "$_wt/ntdll.so" ] && rm -rf "$_wt" 2>/dev/null
done

# ---- keep the Mac awake for the session -----------------------------------
caffeinate -dimsu -w $$ &

# ---- ensure a wine prefix + DXMT's per-prefix dll -------------------------
ensure_prefix(){
    if [ ! -f "$WINEPREFIX/system.reg" ]; then
        export WINEARCH=win64
        "$WINE" wineboot --init >"$OSXEQL_HOME/logs/wineboot.log" 2>&1
        "$WINESERVER" -w
        "$WINE" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1
        "$WINESERVER" -w
    fi
    # DXMT needs winemetal.dll in the prefix's system32 (gotcha #3, 3rd placement);
    # source it from our embedded wine tree.
    local sys32="$WINEPREFIX/drive_c/windows/system32"
    local src="$WINE_DIR/lib/wine/x86_64-windows/winemetal.dll"
    [ -f "$src" ] && [ ! -f "$sys32/winemetal.dll" ] && cp "$src" "$sys32/winemetal.dll" 2>/dev/null
}

# ---- first-run: run the user's Daybreak installer -------------------------
run_installer(){
    local choice setup
    choice=$(osa <<'OSA'
set msg to "Welcome to osxEQL." & return & return & "EverQuest Legends is NOT included — it's Daybreak's game. First download EQLegends_setup.exe from the official site (you need a Daybreak/EQ Legends account). Then choose that file below." & return & return & "osxEQL runs Daybreak's installer, then walks the install through to the login screen."
set r to display dialog msg buttons {"Quit", "Open EQ Legends site", "Choose installer…"} default button "Choose installer…" with title "osxEQL — First-time setup" with icon note
return button returned of r
OSA
)
    case "$choice" in
        "Open EQ Legends site") open "$EQL_URL"; progress QUIT; exit 0 ;;
        "Choose installer…") : ;;
        *) progress QUIT; exit 0 ;;
    esac
    setup=$(osa -e 'POSIX path of (choose file with prompt "Select EQLegends_setup.exe" default location (path to downloads folder))')
    if [ -z "$setup" ] || [ ! -f "$setup" ]; then
        progress QUIT
        alert "No installer selected — setup cancelled."
        exit 1
    fi
    progress PHASE "Setting up the Wine environment"
    progress INDET
    ensure_prefix
    progress PHASE "Installing Daybreak's launcher"
    "$WINE" "$setup" /S >"$OSXEQL_HOME/logs/install.log" 2>&1
    "$WINESERVER" -w 2>/dev/null
    if [ ! -f "$BOOT_LP" ] && [ ! -f "$GAME_LP" ]; then
        progress FAIL "Daybreak's installer didn't produce a launcher"
        progress DETAIL "See install.log in ~/Library/Application Support/osxEQL/logs"
        alert "Daybreak's installer finished but LaunchPad wasn't found. See logs/install.log in ~/Library/Application Support/osxEQL."
        exit 1
    fi
}

# ---- pre-fix Daybreak's Path="C:" registration bug -------------------------
# The silent installer drops LaunchPad at C:\ and registers the app with the
# literal path "C:" in ApplicationRegistry.xml. Under wine the self-patcher then
# writes the whole updated launcher into a folder NAMED "C:" under Installed
# Games and dies with InitWebCoreFailed (issue #2 / first-run capture
# 2026-07-12). Moving the bootstrap into the game dir and fixing the
# registration BEFORE the first boot makes the self-patch land in place, so the
# first run reaches the login screen.
fix_application_registry(){
    local reg
    for reg in "$WINEPREFIX"/drive_c/users/*/AppData/LocalLow/"Daybreak Game Company"/ApplicationRegistry.xml; do
        [ -f "$reg" ] || continue
        /usr/bin/python3 - "$reg" <<'PY'
import sys
p = sys.argv[1]
s = open(p, "r").read()
s = s.replace('Path="C:"', 'Path="C:\\users\\Public\\Daybreak Game Company\\Installed Games\\EverQuest Legends"')
open(p, "w").write(s)
PY
    done
}
post_install_fixup(){
    [ -f "$BOOT_LP" ] || return 0
    [ -f "$GAME_LP" ] && return 0
    mkdir -p "$GAME_DIR"
    mv -f "$BOOT_LP" "$GAME_LP" 2>/dev/null || cp -f "$BOOT_LP" "$GAME_LP"
    mv -f "$WINEPREFIX/drive_c/LaunchPad.ini" "$WINEPREFIX/drive_c/LaunchPad.ico" "$GAME_DIR/" 2>/dev/null
    fix_application_registry
    echo "pre-fixed LaunchPad location + ApplicationRegistry path" >> "$LOG"
}

# ---- self-heal the installer path-resolution bug (creates literal 'C:' folder)
heal_misplaced_installer(){
    if [ -d "$MISPLACED_DIR" ]; then
        echo "fixing misplaced installer files..." >> "$LOG"
        mkdir -p "$GAME_DIR"
        cp -Rf "$MISPLACED_DIR/"* "$GAME_DIR/" 2>/dev/null || true
        rm -rf "$MISPLACED_DIR"
        if [ -d "$WINEPREFIX/drive_c/LaunchPad.libs" ]; then
            mkdir -p "$GAME_DIR/LaunchPad.libs"
            cp -Rf "$WINEPREFIX/drive_c/LaunchPad.libs/"* "$GAME_DIR/LaunchPad.libs/" 2>/dev/null || true
            rm -rf "$WINEPREFIX/drive_c/LaunchPad.libs"
        fi
        [ -f "$BOOT_LP" ] && [ ! -f "$GAME_LP" ] && cp -f "$BOOT_LP" "$GAME_LP" 2>/dev/null
        fix_application_registry
    fi
}

# ---- match the EQ window to our Wine virtual desktop (project gotcha #4) ----
fix_eqclient(){
    local ini="$GAME_DIR/eqclient.ini"
    [ -f "$ini" ] || return 0
    [ -f "$ini.osxeql-bak" ] || cp "$ini" "$ini.osxeql-bak"
    /usr/bin/python3 - "$ini" "$OSXEQL_W" "$OSXEQL_H" <<'PY'
import sys, re
p, w, h = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, "rb").read().decode("latin-1")          # eqclient.ini is CRLF/latin-1
def setk(k, v, s):
    pat = re.compile(r'(?im)^(\s*' + re.escape(k) + r'\s*=).*?(\r?)$')
    return pat.sub(lambda m: m.group(1) + v + (m.group(2) or "\r"), s) if pat.search(s) else s
# Pin windowed AND fullscreen sizes to the virtual-desktop size: EQ's in-game
# fullscreen toggle uses Width/Height, so both modes stay 1:1 with the desktop.
for k, v in (("Fullscreen", "0"), ("Width", w), ("Height", h),
             ("WindowedWidth", w), ("WindowedHeight", h)):
    s = setk(k, v, s)
open(p, "wb").write(s.encode("latin-1"))
PY
}

# ---- install supervisor: tail LaunchPad's logs into the setup window --------
# Log vocabulary (verified against captured first-install logs, 2026-07-12;
# reference: docs/LAUNCHPAD-LOGS.md):
#   GameLauncher.log        TransitionState … newState=SelfPatch|…|DisplayingMainScreen
#   SelfPatchProgress.log   downloaded=N, totalToDownload=N       (launcher update)
#   PatcherProgress.log     OnDownloadProgress - progress=N%, downloaded=…  (game)
#                           OnInstallProgress - progress=N%, …
#   PatcherEvents.log       OnStateChange … newState=ready|readyIdle|launched
LAST_PHASE=""; READY_SENT=0; DONE_SENT=0; INI_PINNED=0; STAMP="$OSXEQL_HOME/.install-run-stamp"
phase_once(){ [ "$LAST_PHASE" = "$1" ] || { LAST_PHASE="$1"; progress PHASE "$1"; }; }
fmt_gb(){ /usr/bin/awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }
fmt_mb(){ /usr/bin/awk -v b="$1" 'BEGIN{printf "%.0f", b/1048576}'; }

parse_launchpad_logs(){
    local gl="$LP_LOGS/GameLauncher.log" sp="$LP_LOGS/SelfPatchProgress.log"
    local pp="$LP_LOGS/PatcherProgress.log" pe="$LP_LOGS/PatcherEvents.log"
    local state sline dl tot pct ev

    # launcher lifecycle
    if [ -f "$gl" ] && [ "$gl" -nt "$STAMP" ]; then
        state="$(tail -c 12000 "$gl" 2>/dev/null | grep -o 'newState=[A-Za-z]*' | tail -1 | cut -d= -f2)"
        case "$state" in
            SelfPatch)
                phase_once "Launcher updating itself"
                sline="$(tail -c 3000 "$sp" 2>/dev/null | grep -oE 'downloaded=[0-9]+, totalToDownload=[0-9]+' | tail -1)"
                if [ -n "$sline" ]; then
                    dl="${sline#downloaded=}"; dl="${dl%%,*}"
                    tot="${sline##*totalToDownload=}"
                    if [ "${tot:-0}" -gt 0 ] 2>/dev/null; then
                        progress PROGRESS $(( dl * 100 / tot ))
                        progress DETAIL "$(fmt_mb "$dl") of $(fmt_mb "$tot") MB"
                    fi
                fi
                ;;
            InitializingEngine|LoadingMainScreen)
                phase_once "Starting the launcher"
                progress INDET
                ;;
            DisplayingMainScreen)
                if [ "$READY_SENT" = 0 ]; then
                    READY_SENT=1
                    progress READY "LaunchPad is ready — log in there"
                    progress DETAIL "You can close this window; it keeps tracking the install if you leave it open."
                    progress INDET
                    osa -e 'display notification "Log in in the LaunchPad window." with title "osxEQL" sound name "Glass"' &
                fi
                ;;
        esac
    fi

    # game download / install (starts after the user logs in and picks install)
    if [ -f "$pp" ] && [ "$pp" -nt "$STAMP" ]; then
        sline="$(tail -c 6000 "$pp" 2>/dev/null | grep -oE 'OnDownloadProgress - progress=[0-9]+%, downloaded=[0-9]+, totalToDownload=[0-9]+' | tail -1)"
        if [ -n "$sline" ]; then
            pct="$(printf '%s' "$sline" | grep -oE 'progress=[0-9]+' | head -1 | cut -d= -f2)"
            dl="$(printf '%s' "$sline" | grep -oE 'downloaded=[0-9]+' | cut -d= -f2)"
            tot="$(printf '%s' "$sline" | grep -oE 'totalToDownload=[0-9]+' | cut -d= -f2)"
            if [ "${pct:-100}" -lt 100 ] 2>/dev/null; then
                phase_once "Downloading EverQuest Legends"
                progress PROGRESS "$pct"
                progress DETAIL "$(fmt_gb "$dl") of $(fmt_gb "$tot") GB"
            else
                sline="$(tail -c 6000 "$pp" 2>/dev/null | grep -oE 'OnInstallProgress - progress=[0-9]+' | tail -1)"
                pct="${sline##*=}"
                if [ -n "$pct" ] && [ "$pct" -lt 100 ] 2>/dev/null; then
                    phase_once "Installing game files"
                    progress PROGRESS "$pct"
                    progress DETAIL ""
                fi
            fi
        fi
    fi

    # terminal states
    if [ -f "$pe" ] && [ "$pe" -nt "$STAMP" ]; then
        ev="$(tail -c 4000 "$pe" 2>/dev/null | grep -o 'newState=[A-Za-z]*' | tail -1 | cut -d= -f2)"
        case "$ev" in
            ready|readyIdle)
                if [ "$INI_PINNED" = 0 ] && [ -f "$GAME_DIR/eqclient.ini" ]; then
                    fix_eqclient; INI_PINNED=1
                fi
                if [ "$DONE_SENT" = 0 ] && [ -f "$GAME_DIR/eqgame.exe" ]; then
                    DONE_SENT=1
                    progress DONE "EverQuest Legends is installed — press PLAY in LaunchPad"
                fi
                ;;
            launched)
                [ "$INI_PINNED" = 0 ] && [ -f "$GAME_DIR/eqclient.ini" ] && { fix_eqclient; INI_PINNED=1; }
                if [ "$DONE_SENT" = 0 ]; then
                    DONE_SENT=1
                    progress DONE "EverQuest Legends is installed and running"
                fi
                ;;
        esac
    fi
}

install_flow(){
    start_progress_window
    progress PHASE "Setting up the Wine environment"
    progress INDET
    ensure_prefix
    heal_misplaced_installer          # leftovers from an older interrupted install
    if [ ! -f "$GAME_LP" ] && [ ! -f "$BOOT_LP" ]; then
        progress PHASE "Waiting for EQLegends_setup.exe"
        progress DETAIL "Pick the installer in the dialog — download it from everquest.com if needed."
        run_installer
        progress DETAIL ""
    fi
    post_install_fixup

    : > "$LOG"
    touch "$STAMP"
    local attempt=1 max=3 lp_winpath wine_pid
    while :; do
        if [ -f "$GAME_LP" ]; then lp_winpath="$GAME_WINDIR\\LaunchPad.exe"; else lp_winpath="$BOOT_WINPATH"; fi
        phase_once "Starting the launcher"
        progress INDET
        mkdir -p "$GAME_DIR"
        cd "$GAME_DIR" 2>/dev/null || cd "$WINEPREFIX/drive_c"
        "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" "$lp_winpath" >>"$LOG" 2>&1 &
        wine_pid=$!
        while kill -0 "$wine_pid" 2>/dev/null; do
            if [ "$DONE_SENT" = 1 ]; then sleep 20; else parse_launchpad_logs; sleep 2; fi
        done
        wait "$wine_pid" 2>/dev/null

        # died before the login screen with the misplaced-C: signature → heal, retry
        if [ -d "$MISPLACED_DIR" ] && [ "$READY_SENT" = 0 ] && [ "$attempt" -lt "$max" ]; then
            attempt=$((attempt+1))
            LAST_PHASE=""
            progress PHASE "Repairing the launcher install"
            progress INDET
            heal_misplaced_installer
            continue
        fi
        break
    done
    rm -f "$STAMP"

    if [ "$DONE_SENT" = 1 ] || [ "$READY_SENT" = 1 ]; then
        progress QUIT
    else
        progress FAIL "The launcher stopped before finishing"
        progress DETAIL "Log: ~/Library/Application Support/osxEQL/logs/app-launch.log"
    fi
}

# ---- go ---------------------------------------------------------------------
if [ ! -f "$GAME_DIR/eqgame.exe" ]; then
    install_flow
    exit 0
fi

# PLAY mode — game is installed; straight to LaunchPad (no window)
heal_misplaced_installer
fix_eqclient
if [ -f "$GAME_LP" ]; then
    LP_WINPATH="$GAME_WINDIR\\LaunchPad.exe"
else
    LP_WINPATH="$BOOT_WINPATH"
fi
cd "$GAME_DIR" 2>/dev/null || cd "$WINEPREFIX/drive_c"
# LaunchPad in a wine virtual desktop (avoids its splash-window deadlock).
exec "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" "$LP_WINPATH" >"$LOG" 2>&1
