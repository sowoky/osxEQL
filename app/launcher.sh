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
# ultrawide and the built-in display just works. Precedence (same as
# resolve_size in engine/lib.sh):
#   1. OSXEQL_W/OSXEQL_H env vars
#   2. ~/Library/Application Support/osxEQL/resolution — "WxH" pin or "auto"
#   3. default ("max"): exactly the current main display, in points.
# Max by default because EQ's in-game fullscreen requests a display mode of
# Width x Height, and a virtual desktop only offers its own size plus smaller
# standard modes: at any odd size EQ falls back to a low mode (1280x960), the
# desktop shrinks and the mouse is clipped. At the display size the mode exists.
# OSXEQL_FULLDISPLAY=1 when the size IS the display (see fix_eqclient).
resolve_size(){
    local mode="max" pin="" disp dw dh
    OSXEQL_FULLDISPLAY=0
    [ -f "$OSXEQL_HOME/resolution" ] && pin="$(tr -cd '0-9xa-z' < "$OSXEQL_HOME/resolution")"
    if [ -n "${OSXEQL_W:-}" ] && [ -n "${OSXEQL_H:-}" ]; then
        mode="env"
    else
        case "$pin" in
            auto)          mode="auto" ;;
            [0-9]*x[0-9]*) mode="pin"; OSXEQL_W="${pin%%x*}"; OSXEQL_H="${pin##*x}" ;;
        esac
    fi
    # main-display size in points via CoreGraphics — fast, no permission prompts
    disp="$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const d=$.CGMainDisplayID(); $.CGDisplayPixelsWide(d)+"x"+$.CGDisplayPixelsHigh(d)' 2>/dev/null)"
    dw="${disp%%x*}"; dh="${disp##*x}"
    case "${dw}${dh}" in *[!0-9]*|"") dw=1920; dh=1080 ;; esac
    case "$mode" in
        max)  OSXEQL_W="$dw"; OSXEQL_H="$dh" ;;
        auto) OSXEQL_W=$((dw - 40)); OSXEQL_H=$((dh - 60)) ;;
    esac
    [ "$OSXEQL_W" = "$dw" ] && [ "$OSXEQL_H" = "$dh" ] && OSXEQL_FULLDISPLAY=1
    return 0
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
    alert "This app is missing its Wine runtime (Contents/Resources/Wine). Re-download the full app from GitHub."
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
    /usr/bin/python3 - "$ini" "$OSXEQL_W" "$OSXEQL_H" "$OSXEQL_FULLDISPLAY" <<'PY'
import sys, re
p, w, h, fulldisplay = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
s = open(p, "rb").read().decode("latin-1")          # eqclient.ini is CRLF/latin-1
def setk(k, v, s):
    pat = re.compile(r'(?im)^(\s*' + re.escape(k) + r'\s*=).*?(\r?)$')
    return pat.sub(lambda m: m.group(1) + v + (m.group(2) or "\r"), s) if pat.search(s) else s
# Pin windowed AND fullscreen sizes to the virtual-desktop size: EQ's in-game
# fullscreen toggle uses Width/Height, so both modes stay 1:1 with the desktop.
# At the exact display size the player's Fullscreen choice is kept (both modes are
# the same size); at any other size Fullscreen=0 is forced, because a fullscreen
# request there makes EQ fall back to a low display mode.
keys = [("Width", w), ("Height", h), ("WindowedWidth", w), ("WindowedHeight", h)]
if not fulldisplay:
    keys.insert(0, ("Fullscreen", "0"))
for k, v in keys:
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

# ---- EQBuddy Evolved companion (optional; see Resources/eqbuddy.sh) --------
# Asks ONCE (answer stored in $OSXEQL_HOME/eqbuddy), then starts EQBuddy with the
# game on every PLAY launch. Nothing here may stop the game from launching: any
# failure is logged, told to the user, and the launch continues.
EQBUDDY_LIB="$RES/eqbuddy.sh"
[ -f "$EQBUDDY_LIB" ] && . "$EQBUDDY_LIB"
EQBUDDY_FOCUS_BIN="$RES/eqbuddy-focus"      # built by packaging/build-app.sh

eqbuddy_offer(){
    local choice setup eqlog="$OSXEQL_HOME/logs/eqbuddy-install.log"
    choice=$(osa <<'OSA'
set msg to "osxEQL can start EQBuddy Evolved — a companion widget that reads your EverQuest log (kills, DPS, loot, timers…) — together with the game." & return & return & "It is downloaded from its official GitHub release (DranakCorps-bot/EQBuddy), checked against its published SHA-256, and installed into the game's Wine prefix. EQBuddy is a separate product by its own author, not part of osxEQL." & return & return & "Change this any time with: osxeql eqbuddy desktop|window|off"
set r to display dialog msg buttons {"No thanks", "Install EQBuddy"} default button "Install EQBuddy" with title "osxEQL — EQBuddy Evolved" with icon note
return button returned of r
OSA
)
    case "$choice" in
        "Install EQBuddy") : ;;
        "No thanks") eqbuddy_set_mode off; return 0 ;;
        *) return 0 ;;   # dialog dismissed: ask again next launch
    esac
    osa -e 'display notification "Downloading EQBuddy Evolved…" with title "osxEQL"' &
    if ! setup="$(eqbuddy_download "$OSXEQL_HOME/cache" 2>>"$eqlog")"; then
        alert "EQBuddy could not be downloaded or failed its SHA-256 check (see logs/eqbuddy-install.log). The game will start without it; osxEQL will ask again next launch."
        return 0
    fi
    eqbuddy_set_mode window
    # Install in the background; the installer's own finish step starts EQBuddy
    # (as its own window, floating over the game).
    "$WINE" "$setup" "${EQBUDDY_SETUP_ARGS[@]}" >>"$eqlog" 2>&1 &
    # Record the version for auto-update. If this install fails, EQBuddy.exe is
    # missing next launch and eqbuddy_update reinstalls it.
    command -v eqbuddy_mark_installed >/dev/null 2>&1 && eqbuddy_mark_installed "$setup"
    osa -e 'display notification "Installing EQBuddy Evolved — it opens when ready." with title "osxEQL"' &
    EQBUDDY_JUST_INSTALLED=1
}

start_eqbuddy(){
    command -v eqbuddy_mode >/dev/null 2>&1 || return 0   # older bundle without the lib
    EQBUDDY_JUST_INSTALLED=0
    if [ "$(eqbuddy_mode)" = unset ]; then
        eqbuddy_offer
    fi
    [ "$EQBUDDY_JUST_INSTALLED" = 1 ] && return 0
    echo "==== $(date) ====" >> "$OSXEQL_HOME/logs/eqbuddy.log"
    # Update to the latest EQBuddy release if there is one, then start it — in the
    # background, so LaunchPad never waits on a download (older libs: plain launch).
    if command -v eqbuddy_update_and_launch >/dev/null 2>&1; then
        eqbuddy_update_and_launch "$OSXEQL_W" "$OSXEQL_H" "$OSXEQL_HOME/logs/eqbuddy.log"
    else
        eqbuddy_launch "$OSXEQL_W" "$OSXEQL_H" "$OSXEQL_HOME/logs/eqbuddy.log"
    fi
}

# ---- settings & troubleshooting menu: hold ⌥ Option while opening the app ----
# For players who only have the .app: every EQBuddy switch the CLI has
# (osxeql eqbuddy …) as a plain macOS list, plus a one-click diagnostics zip to
# attach to a bug report. The settings are the same small files in $OSXEQL_HOME.
option_held(){
    # NSEvent.modifierFlags is a class property: no Accessibility permission needed.
    [ "$(osa -l JavaScript -e 'ObjC.import("AppKit"); ($.NSEvent.modifierFlags & 0x80000) ? "1" : "0"')" = 1 ]
}
_flag(){ local f="$OSXEQL_HOME/$1"; if [ -f "$f" ]; then tr -cd 'a-z' < "$f"; else printf '%s' "$2"; fi; }
_onoff(){ [ "$1" = off ] && echo OFF || echo ON; }
_toggle(){ if [ "$(_flag "$1" on)" = off ]; then echo on > "$OSXEQL_HOME/$1"; else echo off > "$OSXEQL_HOME/$1"; fi; }

collect_diagnostics(){
    local stamp tmp out so
    stamp="$(date +%Y%m%d-%H%M%S)"
    tmp="$(mktemp -d)/osxEQL-Buddy-diagnostics-$stamp"
    out="$HOME/Desktop/osxEQL-Buddy-diagnostics-$stamp.zip"
    mkdir -p "$tmp"
    {
        echo "osxEQL-Buddy $(/usr/bin/defaults read "$SELF/../Info" CFBundleShortVersionString 2>/dev/null)"
        /usr/bin/sw_vers
        /usr/sbin/sysctl -n hw.model machdep.cpu.brand_string hw.memsize
        echo "game window: ${OSXEQL_W}x${OSXEQL_H}"
        for f in eqbuddy eqbuddy-autohide eqbuddy-autoclose eqbuddy-autoupdate eqbuddy-helper resolution eqbuddy-installed.sha256; do
            echo "$f: $(cat "$OSXEQL_HOME/$f" 2>/dev/null || echo '(default)')"
        done
        for so in winemac.so.osxeql-overlay winecoreaudio.so.osxeql-audiofix; do
            [ -f "$WINE_DIR/lib/wine/x86_64-unix/$so" ] && echo "patched: $so" || echo "not patched: $so"
        done
        echo "--- processes"; /bin/ps -axo pid,rss,%cpu,command | grep -iE 'eqgame|eqbuddy|LaunchPad|wineserver' | grep -v grep
    } > "$tmp/summary.txt" 2>&1
    cp -R "$OSXEQL_HOME/logs" "$tmp/logs" 2>/dev/null
    cp "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/"EQBuddy Evolved"/error.log "$tmp/eqbuddy-error.log" 2>/dev/null
    grep -A12 -i '^\[VideoMode\]' "$GAME_DIR/eqclient.ini" > "$tmp/eqclient-videomode.txt" 2>/dev/null
    if /usr/bin/ditto -c -k --keepParent "$tmp" "$out"; then
        open -R "$out"
        osa -e "display alert \"osxEQL-Buddy\" message \"Diagnostics saved on your Desktop:\n$(basename "$out")\n\nAttach it to your bug report. It contains osxEQL-Buddy's logs and settings (no passwords).\""
    else
        alert "Could not write the diagnostics zip to your Desktop."
    fi
    rm -rf "$(dirname "$tmp")"
}

# ---- oversized EverQuest logs (see gamelog_* in Resources/eqbuddy.sh) -------------
# $1 = minimum size in MB ("" = the threshold). Lists the logs, asks, archives.
# Returns 0 when it archived something.
archive_game_logs_dialog(){
    local min="${1:-$(gamelog_threshold_mb)}" files desc msg btn moved
    if gamelog_game_running; then
        alert "Quit EverQuest first — its logs can't be archived while the game is running."; return 1
    fi
    files="$(gamelog_list "$min")"
    if [ -z "$files" ]; then
        osa -e "display alert \"osxEQL-Buddy\" message \"No game log to archive (none over $min MB).\""; return 1
    fi
    desc="$(printf '%s\n' "$files" | gamelog_describe | awk '{printf "%s\\n", $0}')"
    msg="These EverQuest logs will be moved to the Logs/archive folder (nothing is deleted):\n\n${desc}\nEverQuest starts a fresh log the next time you /log. EQBuddy keeps its own history."
    btn="$(osa -e "button returned of (display dialog \"$msg\" with title \"osxEQL-Buddy\" buttons {\"Cancel\", \"Archive\"} default button \"Archive\" cancel button \"Cancel\")")"
    [ "$btn" = Archive ] || return 1
    if moved="$(printf '%s\n' "$files" | gamelog_archive)"; then
        btn="$(osa -e "button returned of (display dialog \"Done — $moved MB moved to Logs/archive. You can delete that folder whenever you like.\" with title \"osxEQL-Buddy\" buttons {\"Show archive\", \"OK\"} default button \"OK\")")"
        [ "$btn" = "Show archive" ] && open "$(gamelog_dir)/archive"
        return 0
    fi
    alert "Could not archive the logs (see the Logs folder)."; return 1
}

# Once per launch: a log over the threshold slows the game down — offer to archive it.
check_big_game_logs(){
    local files desc btn
    command -v gamelog_list >/dev/null 2>&1 || return 0
    [ "$(_flag log-check on)" = off ] && return 0
    gamelog_game_running && return 0
    files="$(gamelog_list "$(gamelog_threshold_mb)")"
    [ -n "$files" ] || return 0
    desc="$(printf '%s\n' "$files" | gamelog_describe | awk '{printf "%s\\n", $0}')"
    btn="$(osa -e "button returned of (display dialog \"Your EverQuest log is getting big:\n\n${desc}\nVery large logs make the game (and EQBuddy) stutter and freeze. Archive it now? It is moved, not deleted.\" with title \"osxEQL-Buddy\" buttons {\"Never ask\", \"Not now\", \"Archive\"} default button \"Archive\" with icon caution)")"
    case "$btn" in
        Archive)
            if printf '%s\n' "$files" | gamelog_archive >/dev/null; then
                osa -e 'display notification "Game log archived (Logs/archive)." with title "osxEQL-Buddy"' &
            fi ;;
        "Never ask") echo off > "$OSXEQL_HOME/log-check" ;;
    esac
    return 0
}

settings_menu(){
    local choice mode list i items largest
    while :; do
        mode="$(_flag eqbuddy unset)"
        largest="$(gamelog_list 0 | while IFS= read -r i; do gamelog_mb "$i"; done | sort -n | tail -1)"
        items=(
            "EQBuddy: $(case "$mode" in (window|desktop) echo ON ;; (*) echo OFF ;; esac)"
            "Hide EQBuddy when another app is in front: $(_onoff "$(_flag eqbuddy-autohide on)")"
            "Close EQBuddy with the game: $(_onoff "$(_flag eqbuddy-autoclose on)")"
            "Update EQBuddy automatically: $(_onoff "$(_flag eqbuddy-autoupdate on)")"
            "EQBuddy helper (alert sounds, hide, close): $(_onoff "$(_flag eqbuddy-helper on)")"
            "Archive game logs (largest: ${largest:-0} MB)"
            "Warn me when a game log is over $(gamelog_threshold_mb) MB: $(_onoff "$(_flag log-check on)")"
            "Collect diagnostics (zip on the Desktop)"
            "Open the logs folder"
            "Quit without playing"
        )
        list=""; for i in "${items[@]}"; do list="$list${list:+, }\"$i\""; done
        choice="$(osa -e "choose from list {$list} with title \"osxEQL-Buddy\" with prompt \"Settings & troubleshooting. Pick a line to change it — Play starts the game. (Stutters? Try the game with EQBuddy OFF, then EQBuddy ON with its helper OFF.)\" OK button name \"Change\" cancel button name \"Play\"")"
        case "$choice" in
            ""|false)        return 0 ;;
            "EQBuddy: ON")   eqbuddy_set_mode off ;;
            "EQBuddy: OFF")  eqbuddy_set_mode window ;;   # installed on launch if missing
            Hide*)           _toggle eqbuddy-autohide ;;
            Close*)          _toggle eqbuddy-autoclose ;;
            Update*)         _toggle eqbuddy-autoupdate ;;
            "EQBuddy helper"*) _toggle eqbuddy-helper ;;
            "Archive game logs"*) archive_game_logs_dialog 1 ;;   # every log over 1 MB
            Warn*)           _toggle log-check ;;
            Collect*)        collect_diagnostics ;;
            Open*)           open "$OSXEQL_HOME/logs" ;;
            Quit*)           exit 0 ;;
        esac
    done
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
command -v eqbuddy_set_mode >/dev/null 2>&1 && option_held && settings_menu
check_big_game_logs
start_eqbuddy
# LaunchPad in a wine virtual desktop (avoids its splash-window deadlock).
exec "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" "$LP_WINPATH" >"$LOG" 2>&1
