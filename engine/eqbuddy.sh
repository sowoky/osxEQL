#!/bin/bash
# EQBuddy Evolved companion — install it into the osxEQL prefix and start it
# alongside the game.
#
# EQBuddy Evolved (github.com/DranakCorps-bot/EQBuddy) is a Windows-only WPF widget
# that tails EQ's /log file. Run inside the SAME prefix as the game it sees the
# prefix's drive_c as C:\ and finds the logs on its own — no configuration.
#
# EQBuddy Evolved is proprietary: osxEQL NEVER bundles or redistributes it. We fetch
# the official signed installer from the upstream GitHub release, verify it against
# the SHA-256 the release publishes next to it, and run it unmodified.
#
# Sourced by engine/osxeql (after lib.sh) and by the .app launcher (copied to
# Contents/Resources/eqbuddy.sh). Callers must set WINE, WINEPREFIX and OSXEQL_HOME,
# and the wine environment (see wine_env / the launcher's exports).
#
# Mode file $OSXEQL_HOME/eqbuddy — one word:
#   window   start EQBuddy as its own Mac window, floating over the game (the
#            default). Over a FULLSCREEN game only with the patched winemac.so
#            (engine/overlay.sh) — see eqbuddy_sync_float.
#   desktop  start EQBuddy INSIDE the game's Wine virtual desktop (experimental:
#            the game can draw over it)
#   off      never start it (and never ask again)
#   (absent) not decided yet — the .app asks once on the next PLAY launch

EQBUDDY_MODE_FILE="$OSXEQL_HOME/eqbuddy"
EQBUDDY_SETUP_NAME="EQBuddyEvolvedSetup.exe"
# releases/latest is the Evolved (v2) line upstream. If a release ever lacks the
# Evolved installer, the download 404s and we fail cleanly — nothing is guessed.
EQBUDDY_RELEASE_URL="${OSXEQL_EQBUDDY_URL:-https://github.com/DranakCorps-bot/EQBuddy/releases/latest/download}"

eqbuddy_mode() {
    local m
    m="$( [ -f "$EQBUDDY_MODE_FILE" ] && tr -cd 'a-z' < "$EQBUDDY_MODE_FILE")"
    case "$m" in
        desktop|window|off) echo "$m" ;;
        *)                  echo unset ;;
    esac
}

eqbuddy_set_mode() { echo "$1" > "$EQBUDDY_MODE_FILE"; }

# Unix path of the installed EQBuddy.exe, or nothing. The installer runs per-user
# (PrivilegesRequired=lowest → {userpf}), so it normally lands under
# users/<name>/AppData/Local/Programs; the Program Files arms cover an admin install.
eqbuddy_exe() {
    local c
    for c in "$WINEPREFIX"/drive_c/users/*/AppData/Local/Programs/"EQBuddy Evolved"/EQBuddy.exe \
             "$WINEPREFIX/drive_c/Program Files/EQBuddy Evolved/EQBuddy.exe" \
             "$WINEPREFIX/drive_c/Program Files (x86)/EQBuddy Evolved/EQBuddy.exe"; do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# drive_c-relative unix path -> C:\ windows path (no wine process needed).
eqbuddy_winpath() {
    local rel="${1#"$WINEPREFIX/drive_c/"}"
    printf 'C:\\%s\n' "${rel//\//\\}"
}

eqbuddy_running() { pgrep -f 'EQBuddy\.exe' >/dev/null 2>&1; }

# Download + verify the official installer into $1 (a directory). Prints the path.
eqbuddy_download() {
    local dir="$1" exe sha want got
    exe="$dir/$EQBUDDY_SETUP_NAME"; sha="$exe.sha256"
    mkdir -p "$dir" || return 1
    rm -f "$exe" "$sha"
    curl -fsSL --retry 2 -o "$sha" "$EQBUDDY_RELEASE_URL/$EQBUDDY_SETUP_NAME.sha256" || {
        echo "could not download $EQBUDDY_SETUP_NAME.sha256 from $EQBUDDY_RELEASE_URL" >&2; return 1; }
    curl -fsSL --retry 2 -o "$exe" "$EQBUDDY_RELEASE_URL/$EQBUDDY_SETUP_NAME" || {
        echo "could not download $EQBUDDY_SETUP_NAME from $EQBUDDY_RELEASE_URL" >&2; return 1; }
    # The .sha256 is PowerShell's Get-FileHash (uppercase hex, maybe a BOM): keep hex only.
    want="$(tr -cd '0-9A-Fa-f' < "$sha" | tr 'A-F' 'a-f')"
    got="$(shasum -a 256 "$exe" | cut -d' ' -f1)"
    if [ "${#want}" -ne 64 ] || [ "$want" != "$got" ]; then
        echo "SHA-256 mismatch for $EQBUDDY_SETUP_NAME (expected '$want', got '$got') — refusing to install" >&2
        rm -f "$exe"
        return 1
    fi
    printf '%s\n' "$exe"
}

# ---- keep EQBuddy up to date ------------------------------------------------
# On every launch (the app and `osxeql play`), before EQBuddy starts, compare the
# SHA-256 published next to the latest official installer with the one we last
# installed ($OSXEQL_HOME/eqbuddy-installed.sha256). Different — or EQBuddy missing,
# or no record yet — and the new installer is downloaded, verified exactly like a
# first install, and run silently. One ~64-byte request when nothing changed; offline
# or GitHub down = EQBuddy starts as it is. $OSXEQL_HOME/eqbuddy-autoupdate: on|off
# (absent = on). EQBuddy's own in-app updater is untouched.
EQBUDDY_STAMP="$OSXEQL_HOME/eqbuddy-installed.sha256"
EQBUDDY_AUTOUPDATE_FILE="$OSXEQL_HOME/eqbuddy-autoupdate"

eqbuddy_autoupdate() {
    [ "$( [ -f "$EQBUDDY_AUTOUPDATE_FILE" ] && tr -cd 'a-z' < "$EQBUDDY_AUTOUPDATE_FILE")" = off ] && echo off || echo on
}

# Record what was installed: $1 = the verified setup exe (its .sha256 sits beside it).
eqbuddy_mark_installed() {
    tr -cd '0-9A-Fa-f' < "$1.sha256" | tr 'A-F' 'a-f' > "$EQBUDDY_STAMP"
}

# $1 = log, $2 = mode. Never fatal, never touches a running EQBuddy. Set
# EQBUDDY_FORCE_UPDATE=1 to check even with autoupdate off (osxeql eqbuddy update).
eqbuddy_update() {
    local log="$1" mode="${2:-window}" latest have setup
    [ "$(eqbuddy_autoupdate)" = on ] || [ "${EQBUDDY_FORCE_UPDATE:-0}" = 1 ] || return 0
    eqbuddy_running && { echo "EQBuddy: running — update check skipped" >>"$log"; return 0; }
    latest="$(curl -fsSL --max-time 8 "$EQBUDDY_RELEASE_URL/$EQBUDDY_SETUP_NAME.sha256" 2>>"$log" \
              | tr -cd '0-9A-Fa-f' | tr 'A-F' 'a-f')"
    [ "${#latest}" -eq 64 ] || { echo "EQBuddy: update check failed (offline?) — starting the installed copy" >>"$log"; return 0; }
    have="$( [ -f "$EQBUDDY_STAMP" ] && tr -cd '0-9a-f' < "$EQBUDDY_STAMP")"
    if eqbuddy_exe >/dev/null && [ "$have" = "$latest" ]; then
        echo "EQBuddy: up to date" >>"$log"; return 0
    fi
    echo "EQBuddy: new release (or unknown installed version) — updating" >>"$log"
    setup="$(eqbuddy_download "$OSXEQL_HOME/cache" 2>>"$log")" || { echo "EQBuddy: update download failed — starting the installed copy" >>"$log"; return 0; }
    # The installer starts EQBuddy itself when it finishes: prepare its settings first.
    eqbuddy_sync_sounds "$log"
    eqbuddy_sync_float "$mode" "$log"
    [ "$mode" = window ] && eqbuddy_autohide_prep "$log"
    "$WINE" "$setup" "${EQBUDDY_SETUP_ARGS[@]}" >>"$log" 2>&1 || echo "EQBuddy: installer returned non-zero" >>"$log"
    if eqbuddy_exe >/dev/null; then
        eqbuddy_mark_installed "$setup"
        echo "EQBuddy: updated to the latest release" >>"$log"
    fi
    return 0
}

# Update (if needed), then launch — in the background, so the game never waits on
# a download. Same arguments as eqbuddy_launch.
eqbuddy_update_and_launch() {
    local mode
    mode="$(eqbuddy_mode)"
    case "$mode" in desktop|window) ;; *) return 0 ;; esac
    ( eqbuddy_update "$3" "$mode"; eqbuddy_launch "$1" "$2" "$3" ) &
}

# Inno Setup silent-install arguments. /TASKS="" skips the desktop-shortcut task.
# The installer's [Run] entry starts EQBuddy when it finishes, even when silent.
EQBUDDY_SETUP_ARGS=(/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- '/TASKS=')

# Start the installed EQBuddy per the mode. $1x$2 = the virtual-desktop size (must
# equal the one LaunchPad is started with, or a second, differently sized desktop
# named osxEQL is requested). $3 = log file. Never blocks; never fatal.
eqbuddy_launch() {
    local w="$1" h="$2" log="$3" mode exe
    mode="$(eqbuddy_mode)"
    case "$mode" in desktop|window) ;; *) return 0 ;; esac
    exe="$(eqbuddy_exe)" || { echo "EQBuddy: mode=$mode but EQBuddy.exe is not installed (osxeql eqbuddy install)" >>"$log"; return 0; }
    # A second copy would only ask the running one to show itself (EQBuddy is
    # single-instance), so an already-running EQBuddy is left alone — it may have
    # just been started by the installer of an update — but it still gets its helper.
    eqbuddy_running && { eqbuddy_start_focus_helper "$log" "$mode"; return 0; }
    eqbuddy_sync_sounds "$log"
    eqbuddy_sync_float "$mode" "$log"
    echo "EQBuddy: starting ($mode): $exe" >>"$log"
    if [ "$mode" = desktop ]; then
        "$WINE" explorer "/desktop=osxEQL,${w}x${h}" "$(eqbuddy_winpath "$exe")" >>"$log" 2>&1 &
        eqbuddy_start_focus_helper "$log" desktop
    else
        eqbuddy_autohide_prep "$log"
        "$WINE" "$exe" >>"$log" 2>&1 &
        eqbuddy_start_focus_helper "$log" window
    fi
}

# ---- hide EQBuddy while the game isn't frontmost (window mode) --------------
# EQBuddy's own "Hide when game unfocused" can't see the game here (it lives in a
# separate Wine virtual desktop), so osxEQL does it from the Mac side with the
# eqbuddy-focus helper (engine/tools/eqbuddy-focus.swift). $OSXEQL_HOME/eqbuddy-autohide
# holds on|off; absent = on.
EQBUDDY_AUTOHIDE_FILE="$OSXEQL_HOME/eqbuddy-autohide"
eqbuddy_autohide() {
    [ "$( [ -f "$EQBUDDY_AUTOHIDE_FILE" ] && tr -cd 'a-z' < "$EQBUDDY_AUTOHIDE_FILE")" = off ] && echo off || echo on
}

# The helper: $EQBUDDY_FOCUS_BIN if the caller ships one prebuilt (the .app), else
# built on first use from $EQBUDDY_FOCUS_SRC into $OSXEQL_HOME/bin (the engine).
eqbuddy_focus_bin() {
    local log="$1" bin="${EQBUDDY_FOCUS_BIN:-$OSXEQL_HOME/bin/eqbuddy-focus}"
    if [ -n "${EQBUDDY_FOCUS_SRC:-}" ] && [ -f "$EQBUDDY_FOCUS_SRC" ] \
       && { [ ! -x "$bin" ] || [ "$EQBUDDY_FOCUS_SRC" -nt "$bin" ]; }; then
        mkdir -p "$(dirname "$bin")"
        echo "EQBuddy: building focus helper" >>"$log"
        xcrun swiftc -O -o "$bin" "$EQBUDDY_FOCUS_SRC" -framework AppKit >>"$log" 2>&1 \
            || { echo "EQBuddy: focus helper build failed (Xcode command-line tools?)" >>"$log"; return 1; }
    fi
    [ -x "$bin" ] && printf '%s\n' "$bin"
}

# With autohide on, EQBuddy's own focus hide must be OFF — it would otherwise hide
# the widget for good, since it never sees the game in front. Settings edited only
# while EQBuddy isn't running (it rewrites settings.json on exit).
eqbuddy_autohide_prep() {
    local log="$1" f
    [ "$(eqbuddy_autohide)" = on ] || return 0
    for f in "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/"EQBuddy Evolved"/settings.json; do
        [ -f "$f" ] || continue
        /usr/bin/python3 - "$f" >>"$log" 2>&1 <<'PY' || echo "EQBuddy: could not update $f" >>"$log"
import json, os, sys
p = sys.argv[1]
with open(p, encoding="utf-8-sig") as fh:
    s = json.load(fh)
if s.get("HideWhenGameUnfocused"):
    s["HideWhenGameUnfocused"] = False
    with open(p + ".osxeql-tmp", "w", encoding="utf-8") as fh:
        json.dump(s, fh, indent=2, ensure_ascii=False)
    os.replace(p + ".osxeql-tmp", p)
    print("EQBuddy: HideWhenGameUnfocused turned off (osxEQL's focus helper does it instead) in", p)
PY
    done
}

# The helper does two jobs: autohide (window mode, if on) and alert sounds (always —
# EQBuddy's own player can't play anything under this Wine; see the helper).
eqbuddy_start_focus_helper() {
    local log="$1" mode="${2:-window}" bin ah=off ac
    # Diagnostic switch (osxeql eqbuddy helper off): no helper at all — no autohide,
    # no alert sounds, no autoclose. For bisecting stutters/glitches.
    [ "$( [ -f "$OSXEQL_HOME/eqbuddy-helper" ] && tr -cd 'a-z' < "$OSXEQL_HOME/eqbuddy-helper")" = off ] \
        && { echo "EQBuddy: helper disabled (osxeql eqbuddy helper on)" >>"$log"; return 0; }
    pgrep -qf 'eqbuddy-focus' && return 0
    bin="$(eqbuddy_focus_bin "$log")" || return 0
    [ "$mode" = window ] && [ "$(eqbuddy_autohide)" = on ] && ah=on
    ac="$(eqbuddy_autoclose)"
    echo "EQBuddy: helper $bin (autohide $ah, autoclose $ac, alert sounds via afplay)" >>"$log"
    nohup "$bin" --prefix "$WINEPREFIX" --autohide "$ah" --autoclose "$ac" >>"$log" 2>&1 &
}

# Close EQBuddy when the game closes (done by the helper, 20 s after eqgame exits).
# $OSXEQL_HOME/eqbuddy-autoclose: on|off (absent = on).
EQBUDDY_AUTOCLOSE_FILE="$OSXEQL_HOME/eqbuddy-autoclose"
eqbuddy_autoclose() {
    [ "$( [ -f "$EQBUDDY_AUTOCLOSE_FILE" ] && tr -cd 'a-z' < "$EQBUDDY_AUTOCLOSE_FILE")" = off ] && echo off || echo on
}

# Float over the FULLSCREEN game (window mode only). Needs the patched winemac.so
# (engine/overlay.sh). EQBuddy itself writes the driver knob
# (AppDefaults\EQBuddy.exe\Mac Driver\LetTopmostWindowsFloatOverFullscreen) at
# startup FROM its WineFloatOverFullscreen setting — and writes "N" when the setting
# is off — so the setting, not the registry, is what has to be turned on. The same
# setting makes EQBuddy's windows non-activating, so clicking the widget doesn't pull
# the game out of fullscreen. Edited only while EQBuddy is not running (it rewrites
# settings.json on exit), and only in a profile it already created.
# The knob is ALSO written here, before launch: winemac reads its options when the
# driver initialises — before any of EQBuddy's own code runs — so the value EQBuddy
# writes at startup only counts from its NEXT launch. Pre-writing it makes the very
# launch that follows `osxeql overlay` float.
eqbuddy_sync_float() {
    local mode="$1" log="$2" so f
    [ "$mode" = window ] || return 0
    so="$(dirname "$WINE")/../lib/wine/x86_64-unix/winemac.so"
    # Marker written by engine/overlay.sh = hash of the patched winemac.so installed.
    [ -f "$so.osxeql-overlay" ] || return 0
    [ "$(shasum -a 256 "$so" 2>/dev/null | cut -d' ' -f1)" = "$(tr -cd '0-9a-f' < "$so.osxeql-overlay")" ] || return 0
    for f in "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/"EQBuddy Evolved"/settings.json; do
        [ -f "$f" ] || continue
        /usr/bin/python3 - "$f" >>"$log" 2>&1 <<'PY' || echo "EQBuddy: could not update $f" >>"$log"
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8-sig") as fh:
    s = json.load(fh)
if s.get("WineFloatOverFullscreen") is not True:
    s["WineFloatOverFullscreen"] = True
    with open(p + ".osxeql-tmp", "w", encoding="utf-8") as fh:
        json.dump(s, fh, indent=2, ensure_ascii=False)
    import os; os.replace(p + ".osxeql-tmp", p)
    print("EQBuddy: WineFloatOverFullscreen enabled in", p)
PY
    done
    "$WINE" reg add 'HKCU\Software\Wine\AppDefaults\EQBuddy.exe\Mac Driver' \
        /v LetTopmostWindowsFloatOverFullscreen /t REG_SZ /d Y /f >>"$log" 2>&1 \
        || echo "EQBuddy: could not write the Mac Driver knob" >>"$log"
}

# ---- alert sounds -------------------------------------------------------------
# EQBuddy Evolved plays its seven built-in alert sounds from C:\Windows\Media
# (Windows' own .wav files), and a Wine prefix has none of them: every watch-rule
# sound resolved to "missing", its "Ding" stand-in too, and alerts were silent.
# EQBuddy 1.x's native Mac build (MIT) solved the same gap by mapping the built-ins
# onto the system clips every Mac has (issue #93); we reuse that exact mapping and
# convert the clips to the .wav names Evolved looks for, locally, with afconvert.
# Nothing is shipped; existing files are never overwritten.
EQBUDDY_SOUNDS=(
    "Windows Ding.wav:Ping"
    "Windows Notify.wav:Glass"
    "chimes.wav:Blow"
    "chord.wav:Pop"
    "tada.wav:Hero"
    "Windows Exclamation.wav:Sosumi"
    "Alarm01.wav:Submarine"
)

eqbuddy_mac_sound() {  # $1 = clip name -> path of its .aiff (Ping as last resort)
    local d
    for d in "$HOME/Library/Sounds" /Library/Sounds /System/Library/Sounds; do
        [ -f "$d/$1.aiff" ] && { printf '%s\n' "$d/$1.aiff"; return 0; }
    done
    [ -f /System/Library/Sounds/Ping.aiff ] && { printf '%s\n' /System/Library/Sounds/Ping.aiff; return 0; }
    return 1
}

eqbuddy_sync_sounds() {
    local log="$1" media="$WINEPREFIX/drive_c/windows/Media" entry wav clip src made=0
    command -v afconvert >/dev/null 2>&1 || { echo "EQBuddy: afconvert not found — alert sounds not generated" >>"$log"; return 0; }
    mkdir -p "$media" || return 0
    for entry in "${EQBUDDY_SOUNDS[@]}"; do
        wav="${entry%%:*}"; clip="${entry##*:}"
        [ -s "$media/$wav" ] && continue
        src="$(eqbuddy_mac_sound "$clip")" || { echo "EQBuddy: no macOS sound for $wav" >>"$log"; continue; }
        if afconvert -f WAVE -d LEI16@44100 "$src" "$media/$wav" >>"$log" 2>&1; then
            made=$((made + 1))
        else
            rm -f "$media/$wav"; echo "EQBuddy: could not convert $src" >>"$log"
        fi
    done
    [ "$made" -gt 0 ] && echo "EQBuddy: generated $made alert sound(s) in C:\\windows\\Media from macOS system sounds" >>"$log"
    eqbuddy_canon_wavs "$log" "$media"
    return 0
}

# afconvert writes Apple's "FLLR" padding chunk between "fmt " and "data". Wine's
# DirectShow wave parser (what EQBuddy's WPF MediaPlayer ends up in) refuses such a
# file: every alert failed with 0x80040218 VFW_E_CANNOT_RENDER (2026-09-30). Rewrite
# our seven files as canonical PCM WAV — 44-byte header, "data" right after "fmt ".
# Also repairs files generated by the first version. Files already canonical, and
# files that aren't PCM WAV, are left alone.
eqbuddy_canon_wavs() {
    local log="$1" media="$2" entry files=()
    for entry in "${EQBUDDY_SOUNDS[@]}"; do
        [ -s "$media/${entry%%:*}" ] && files+=("$media/${entry%%:*}")
    done
    [ "${#files[@]}" -gt 0 ] || return 0
    /usr/bin/python3 - "${files[@]}" >>"$log" 2>&1 <<'PY' || echo "EQBuddy: could not normalise alert sounds" >>"$log"
import os, sys, wave
for p in sys.argv[1:]:
    with open(p, "rb") as fh:
        head = fh.read(40)
    # Canonical: RIFF....WAVE "fmt " size 16, then "data" at offset 36.
    if head[12:16] == b"fmt " and head[16:20] == (16).to_bytes(4, "little") and head[36:40] == b"data":
        continue
    try:
        with wave.open(p, "rb") as r:          # skips unknown chunks such as FLLR
            params, frames = r.getparams(), r.readframes(r.getnframes())
    except (wave.Error, EOFError) as e:
        print("EQBuddy: leaving", p, "as is:", e)
        continue
    tmp = p + ".osxeql-tmp"
    with wave.open(tmp, "wb") as w:
        w.setparams(params)
        w.writeframes(frames)
    os.replace(tmp, p)
    print("EQBuddy: normalised", os.path.basename(p), "to canonical PCM WAV")
PY
}

# ---- EverQuest's own log files ------------------------------------------------
# With /log on, EverQuest appends every chat/combat line to
# Logs/eqlog_<character>_<server>.txt forever. Past a few hundred MB, the game — and
# EQBuddy, which tails the file live — hitch on writes: the freezes a player reported
# (2026-10). "Archiving" moves a log into Logs/archive/ with a date stamp; EverQuest
# starts a fresh file on the next /log, and EQBuddy (which only reads Logs/eqlog_*.txt
# directly) picks the new one up. Nothing is deleted: the player decides what to do
# with the archive folder. Never done while the game is running.
GAMELOG_THRESHOLD_FILE="$OSXEQL_HOME/log-threshold-mb"   # default 100
GAMELOG_CHECK_FILE="$OSXEQL_HOME/log-check"              # on|off (startup prompt)

gamelog_dir() {
    printf '%s\n' "$WINEPREFIX/drive_c/users/Public/Daybreak Game Company/Installed Games/EverQuest Legends/Logs"
}

gamelog_threshold_mb() {
    local t
    t="$( [ -f "$GAMELOG_THRESHOLD_FILE" ] && tr -cd '0-9' < "$GAMELOG_THRESHOLD_FILE")"
    printf '%s\n' "${t:-100}"
}

# Size in MB, rounded. wc -c on a regular file is an fstat (instant), and unlike stat
# it means the same thing on macOS and Linux.
gamelog_mb() {
    local b
    b="$(wc -c < "$1" 2>/dev/null | tr -cd '0-9')"
    echo $(( ( ${b:-0} + 524288 ) / 1048576 ))
}

# The game's logs (eqlog_*.txt + dbg.txt), one per line; $1 = minimum size in MB (0 = all).
gamelog_list() {
    local min="${1:-0}" d f
    d="$(gamelog_dir)"
    [ -d "$d" ] || return 0
    for f in "$d"/eqlog_*.txt "$d/dbg.txt"; do
        [ -f "$f" ] || continue
        [ "$(gamelog_mb "$f")" -ge "$min" ] && printf '%s\n' "$f"
    done
}

# "eqlog_Bob_server.txt (412 MB)" lines for a dialog; reads paths on stdin.
gamelog_describe() {
    local f
    while IFS= read -r f; do printf '%s (%s MB)\n' "$(basename "$f")" "$(gamelog_mb "$f")"; done
}

gamelog_game_running() { pgrep -qf 'eqgame\.exe' 2>/dev/null; }

# Move the given logs (paths on stdin) into Logs/archive/<name>-<date>.txt.
# Prints the total MB moved. Refuses while the game runs.
gamelog_archive() {
    local d arch f stamp total=0
    gamelog_game_running && { echo "game running — not archiving" >&2; return 1; }
    d="$(gamelog_dir)"; arch="$d/archive"; stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$arch" || return 1
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        total=$(( total + $(gamelog_mb "$f") ))
        mv -f "$f" "$arch/$(basename "${f%.txt}")-$stamp.txt" || return 1
    done
    printf '%s\n' "$total"
}
