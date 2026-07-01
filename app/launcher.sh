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
export WINEDEBUG="-all"
export WINEDLLOVERRIDES="mscoree,mshtml="
# NEVER export WINELOADER — it makes wine copy the loader to a temp dir for child
# processes which then fail "could not load ntdll.so" (project gotcha #2).

GAME_WINDIR='C:\users\Public\Daybreak Game Company\Installed Games\EverQuest Legends'
GAME_DIR="$WINEPREFIX/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends"
GAME_LP="$GAME_DIR/LaunchPad.exe"
BOOT_LP="$WINEPREFIX/drive_c/LaunchPad.exe"           # where EQLegends_setup.exe /S lands it
BOOT_WINPATH='C:\LaunchPad.exe'
EQL_URL="https://www.everquest.com/"

# ---- window size (project gotcha #4) --------------------------------------
# The Wine virtual desktop AND eqclient.ini's WindowedWidth/Height MUST be the
# same, or EQ maps mouse clicks to the wrong pixels. DXMT's render surface is
# fixed at launch, so do NOT resize the window mid-game — it re-breaks the
# mouse. Default fills the 3840x1600 ultrawide; override with OSXEQL_W/OSXEQL_H.
OSXEQL_W="${OSXEQL_W:-3420}"
OSXEQL_H="${OSXEQL_H:-1505}"

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
for k, v in (("Fullscreen", "0"), ("WindowedWidth", w), ("WindowedHeight", h)):
    s = setk(k, v, s)
open(p, "wb").write(s.encode("latin-1"))
PY
}

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
