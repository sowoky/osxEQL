#!/bin/bash
# Let EQBuddy (or any opted-in topmost window) float over the FULLSCREEN game.
#
# Why: when EQ runs fullscreen, macOS puts its window at a level no ordinary
# topmost window can beat, so EQBuddy's own window disappears behind it (it only
# shows again once the game goes windowed). engine/patches/winemac-overlay.patch
# adds an opt-in per-app knob to winemac.drv (LetTopmostWindowsFloatOverFullscreen)
# that lifts such a window above the fullscreen level. EQBuddy writes that knob for
# itself from its WineFloatOverFullscreen setting, which engine/eqbuddy.sh turns on.
#
# This rebuilds ONLY winemac.so — from the same CodeWeavers CrossOver source the
# runtime was built from (engine/build-wine.sh), plus the patch — and swaps it into
# the Wine runtime(s) in place, keeping a backup. Minutes, not the full 30-60 min
# build. Nothing prebuilt is downloaded; the patch is readable in engine/patches/.
#
#   engine/overlay.sh            patch the runtime(s)
#   engine/overlay.sh --revert   restore the original winemac.so
#   engine/overlay.sh --status   show whether each runtime is patched
#
# Runtimes touched: $WINE_DIR (the engine's) and the installed app's (osxEQL-Buddy.app or osxEQL.app) embedded
# one — each only once if one is a symlink to the other. An .app is re-signed
# ad-hoc afterwards (editing a bundle file breaks its signature).
# Requires: Xcode command-line tools, and bison >= 3 (brew install bison).
# Shared build plumbing: engine/driverlib.sh (also used by engine/audiofix.sh).
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/driverlib.sh"

PATCH="$HERE/patches/winemac-overlay.patch"
SYMBOL=topmost_float_over_fullscreen
MARK=osxeql-overlay

# A BUILT winemac.so carries the patch if it has the patch's global variable. Ask
# nm (the symbol table), not grep for the knob name: clang folds the ASCII literal
# into the inlined ASCII->UTF-16 conversion in get_config_key, so that string is
# not in the binary at all (first real build, 2026-09-29).
built_is_patched() { nm "$1" 2>/dev/null | grep -q "$SYMBOL"; }

# An INSTALLED winemac.so is ours if the marker beside it names its exact hash.
is_patched() { marker_ok "$1" "$MARK"; }

patch_is_applied() {  # judge by the tree, not by patch's exit status (partial = failure)
    [ "$(grep -l "$SYMBOL" \
        "$WINESRC/dlls/winemac.drv/macdrv_cocoa.h" \
        "$WINESRC/dlls/winemac.drv/macdrv_main.c" \
        "$WINESRC/dlls/winemac.drv/cocoa_window.m" 2>/dev/null | wc -l | tr -d ' ')" -eq 3 ]
}

build_winemac() {  # $1 = the runtime's current winemac.so
    [ -f "$PATCH" ] || die "missing $PATCH"
    prepare_tree
    if patch_is_applied; then
        log "overlay patch already applied to the source tree"
    else
        log "applying $(basename "$PATCH")…"
        ( cd "$WINESRC" && patch -p1 --forward --no-backup-if-mismatch < "$PATCH" ) || true
        patch_is_applied || die "the overlay patch does not apply to CrossOver ${CX_VERSION} (see .rej files under $WINESRC/dlls/winemac.drv)"
    fi
    make_driver dlls/winemac.drv/winemac.so "$1" "$LOGDIR/overlay-build.log"
    built_is_patched "$BUILD/dlls/winemac.drv/winemac.so" || die "built winemac.so lacks the patch symbol ($SYMBOL) — see $LOGDIR/overlay-build.log"
    # Same ABI guard as build-app.sh: without this bridge DXMT cannot draw (gotcha #1).
    nm -gU "$BUILD/dlls/winemac.drv/winemac.so" | grep -q macdrv_functions \
        || die "built winemac.so does not export macdrv_functions — refusing to install (gotcha #1)"
}

rts="$(runtimes)"
[ -n "$rts" ] || die "no Wine runtime found (looked in $WINE_DIR and $APP)"

case "${1:-}" in
    --status)
        while IFS= read -r rt; do
            if is_patched "$rt/$UNIXLIB/winemac.so"; then echo "patched:     $rt"
            else echo "not patched: $rt"; fi
        done <<< "$rts"
        ;;
    --revert)
        game_running && die "quit the game and EQBuddy first"
        while IFS= read -r rt; do revert_driver "$rt" winemac.so "$MARK"; done <<< "$rts"
        ;;
    "")
        game_running && die "quit the game and EQBuddy first (winemac.so is in use)"
        built=""
        while IFS= read -r rt; do
            so="$rt/$UNIXLIB/winemac.so"
            if is_patched "$so"; then log "already patched: $rt"; continue; fi
            [ -n "$built" ] || { build_winemac "$so"; built="$BUILD/dlls/winemac.drv/winemac.so"; }
            install_driver "$rt" "$built" winemac.so "$MARK"
        done <<< "$rts"
        log "done. Next: osxeql eqbuddy window (EQBuddy as its own window), then launch the game."
        ;;
    *) die "usage: engine/overlay.sh [--status|--revert]" ;;
esac
