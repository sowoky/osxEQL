#!/bin/bash
# Make the game's sound FOLLOW the macOS default output (Bluetooth headphones dying
# mid-game, switching outputs) instead of staying pinned to the device that was the
# default when the game started.
#
# Why: Wine's CoreAudio driver opens each stream on a HALOutput audio unit pinned to
# one device. When that device vanishes (headphones out of battery), the game's audio
# ends up on the Mac speakers ignoring their volume/mute, and only a game restart
# recovers it. engine/patches/coreaudio-follow-default.py makes streams opened on the
# default device use macOS's DefaultOutput unit, which tracks the default itself.
# Details and the OSXEQL_PIN_AUDIO_DEVICE=1 escape hatch: see that file.
#
# Rebuilds ONLY winecoreaudio.so (same tree/toolchain as engine/overlay.sh — see
# engine/driverlib.sh) and swaps it into the runtime(s), keeping a backup.
#
#   engine/audiofix.sh            patch the runtime(s)
#   engine/audiofix.sh --revert   restore the original winecoreaudio.so
#   engine/audiofix.sh --status   show whether each runtime is patched
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/driverlib.sh"

EDIT="$HERE/patches/coreaudio-follow-default.py"
SO=winecoreaudio.so
TARGET=dlls/winecoreaudio.drv/winecoreaudio.so
MARK=osxeql-audiofix

is_patched() { marker_ok "$1" "$MARK"; }

build_coreaudio() {  # $1 = the runtime's current winemac.so (for make_driver)
    [ -f "$EDIT" ] || die "missing $EDIT"
    prepare_tree
    /usr/bin/python3 "$EDIT" "$WINESRC/dlls/winecoreaudio.drv/coreaudio.c" \
        || die "the audio patch does not fit CrossOver ${CX_VERSION}'s coreaudio.c — nothing changed"
    make_driver "$TARGET" "$1" "$LOGDIR/audiofix-build.log"
    # A global, not the (inlinable) static helper: -O2 may leave no symbol for that.
    nm "$BUILD/$TARGET" 2>/dev/null | grep -q osxeql_follow_default_output \
        || die "built $SO lacks the patch (osxeql_follow_default_output) — see $LOGDIR/audiofix-build.log"
}

rts="$(runtimes)"
[ -n "$rts" ] || die "no Wine runtime found (looked in $WINE_DIR and $APP)"

case "${1:-}" in
    --status)
        while IFS= read -r rt; do
            if is_patched "$rt/$UNIXLIB/$SO"; then echo "patched:     $rt"
            else echo "not patched: $rt"; fi
        done <<< "$rts"
        ;;
    --revert)
        game_running && die "quit the game and EQBuddy first"
        while IFS= read -r rt; do revert_driver "$rt" "$SO" "$MARK"; done <<< "$rts"
        ;;
    "")
        game_running && die "quit the game and EQBuddy first ($SO is in use)"
        built=""
        while IFS= read -r rt; do
            [ -f "$rt/$UNIXLIB/$SO" ] || { warn "no $SO in $rt — skipping"; continue; }
            if is_patched "$rt/$UNIXLIB/$SO"; then log "already patched: $rt"; continue; fi
            [ -n "$built" ] || { build_coreaudio "$rt/$UNIXLIB/winemac.so"; built="$BUILD/$TARGET"; }
            install_driver "$rt" "$built" "$SO" "$MARK"
        done <<< "$rts"
        log "done. The game's sound now follows the macOS output (OSXEQL_PIN_AUDIO_DEVICE=1 to opt out)."
        ;;
    *) die "usage: engine/audiofix.sh [--status|--revert]" ;;
esac
