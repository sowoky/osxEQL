#!/bin/bash
# osxEQL — run EverQuest Legends on Apple Silicon with open-source Wine + DXMT.
#
# This is the app bundle's entry point (becomes Contents/MacOS/osxEQL). The Wine
# runtime (with DXMT baked in) is EMBEDDED in this bundle under Contents/Resources/Wine,
# so the app is self-contained and relocatable. The game client + wine prefix live
# OUTSIDE the app in ~/Library/Application Support/osxEQL (they persist across updates
# and must not bloat the .app).
#
# On first run (no LaunchPad found) it walks the user through Daybreak's installer,
# then opens the launcher. Subsequent runs go straight to the game.
set -u

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
set msg to "Welcome to osxEQL." & return & return & "EverQuest Legends is NOT included — it's Daybreak's game. First download EQLegends_setup.exe from the official site (you need a Daybreak/EQ Legends account). Then choose that file below." & return & return & "osxEQL runs Daybreak's installer, then opens the launcher so you can log in and download the game."
set r to display dialog msg buttons {"Quit", "Open EQ Legends site", "Choose installer…"} default button "Choose installer…" with title "osxEQL — First-time setup" with icon note
return button returned of r
OSA
)
    case "$choice" in
        "Open EQ Legends site") open "$EQL_URL"; exit 0 ;;
        "Choose installer…") : ;;
        *) exit 0 ;;
    esac
    setup=$(osa -e 'POSIX path of (choose file with prompt "Select EQLegends_setup.exe" default location (path to downloads folder))')
    if [ -z "$setup" ] || [ ! -f "$setup" ]; then alert "No installer selected — setup cancelled."; exit 1; fi
    ensure_prefix
    osa -e 'display dialog "Installing the EverQuest launcher — this takes about a minute. Click OK and wait for the launcher window to appear." buttons {"OK"} default button 1 with title "osxEQL" with icon note' >/dev/null
    "$WINE" "$setup" /S >"$OSXEQL_HOME/logs/install.log" 2>&1
    "$WINESERVER" -w 2>/dev/null
    if [ ! -f "$BOOT_LP" ]; then
        alert "Daybreak's installer finished but LaunchPad wasn't found. See logs/install.log in ~/Library/Application Support/osxEQL."
        exit 1
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

# ---- self-heal the installer path-resolution bug (creates literal 'C:' folder)
heal_misplaced_installer(){
    local misplaced="$WINEPREFIX/drive_c/users/Public/Daybreak Game Company/Installed Games/C:"
    if [ -d "$misplaced" ]; then
        echo "fixing misplaced installer files..." >> "$LOG"
        mkdir -p "$GAME_DIR"
        cp -Rf "$misplaced/"* "$GAME_DIR/" 2>/dev/null || true
        rm -rf "$misplaced"
        if [ -f "$BOOT_LP" ]; then
            cp -f "$BOOT_LP" "$GAME_LP" 2>/dev/null || true
        fi
        if [ -d "$WINEPREFIX/drive_c/LaunchPad.libs" ]; then
            cp -Rf "$WINEPREFIX/drive_c/LaunchPad.libs/"* "$GAME_DIR/LaunchPad.libs/" 2>/dev/null || true
            rm -rf "$WINEPREFIX/drive_c/LaunchPad.libs"
        fi
        local reg
        for reg in "$WINEPREFIX"/drive_c/users/*/AppData/LocalLow/Daybreak Game Company/ApplicationRegistry.xml; do
            if [ -f "$reg" ]; then
                /usr/bin/python3 - "$reg" <<'PY'
import sys
p = sys.argv[1]
s = open(p, "r").read()
s = s.replace('Path="C:"', 'Path="C:\\users\\Public\\Daybreak Game Company\\Installed Games\\EverQuest Legends"')
open(p, "w").write(s)
PY
            fi
        done
    fi
}
heal_misplaced_installer

# ---- decide what to launch ------------------------------------------------
if [ -f "$GAME_LP" ]; then
    fix_eqclient
    LP_WINPATH="$GAME_WINDIR\\LaunchPad.exe"
elif [ -f "$BOOT_LP" ]; then
    LP_WINPATH="$BOOT_WINPATH"
else
    run_installer
    LP_WINPATH="$BOOT_WINPATH"
fi

cd "$GAME_DIR" 2>/dev/null || cd "$WINEPREFIX/drive_c"
# LaunchPad in a wine virtual desktop (avoids its splash-window deadlock).
exec "$WINE" explorer "/desktop=osxEQL,${OSXEQL_W}x${OSXEQL_H}" "$LP_WINPATH" >"$LOG" 2>&1
