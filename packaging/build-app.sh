#!/bin/bash
# build-app.sh — assemble the self-contained, relocatable osxEQL.app into dist/.
#
# Embeds the portable Wine runtime (DXMT baked in) under Contents/Resources/Wine.
# The game client + prefix are NOT bundled — they live in ~/Library/Application
# Support/osxEQL and are created on first run.
#
#   packaging/build-app.sh [WINE_SRC]
#     WINE_SRC defaults to ~/Library/Application Support/osxEQL/Wine (the staged,
#     DXMT-baked runtime). Must contain bin/wine + DXMT (winemetal.so/.dll).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WINE_SRC="${1:-$HOME/Library/Application Support/osxEQL/Wine}"
OUT="$REPO/dist/osxEQL.app"

# --- preflight -------------------------------------------------------------
[ -x "$WINE_SRC/bin/wine" ]                                   || { echo "no wine at $WINE_SRC/bin/wine"; exit 1; }
[ -f "$WINE_SRC/lib/wine/x86_64-unix/winemetal.so" ]         || { echo "DXMT not baked into $WINE_SRC (winemetal.so missing) — run: engine/osxeql backend dxmt"; exit 1; }
[ -f "$WINE_SRC/lib/wine/x86_64-windows/winemetal.dll" ]     || { echo "DXMT winemetal.dll missing in $WINE_SRC"; exit 1; }
nm -gU "$WINE_SRC/lib/wine/x86_64-unix/winemac.so" 2>/dev/null | grep -q macdrv_functions \
    || { echo "FATAL: $WINE_SRC winemac.so does not export macdrv_functions — DXMT cannot create a Metal view (gotcha #1)"; exit 1; }
[ -f "$REPO/assets/icon/AppIcon.icns" ]                      || { echo "missing assets/icon/AppIcon.icns — run assets/icon/generate.py + build_icns.sh"; exit 1; }

# --- assemble --------------------------------------------------------------
echo "assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
install -m 0755 "$REPO/app/launcher.sh" "$OUT/Contents/MacOS/osxEQL"
cp "$REPO/app/Info.plist"        "$OUT/Contents/Info.plist"
cp "$REPO/assets/icon/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
echo "copying Wine runtime ($(du -sh "$WINE_SRC" | cut -f1)) — a moment…"
ditto "$WINE_SRC" "$OUT/Contents/Resources/Wine"

# --- sign (ad-hoc) + clean -------------------------------------------------
xattr -cr "$OUT" 2>/dev/null || true
echo "ad-hoc signing…"
codesign --force --deep --sign - "$OUT" 2>&1 | tail -2 || { echo "codesign failed"; exit 1; }
codesign --verify --deep "$OUT" && echo "signature OK"

echo "built: $OUT  ($(du -sh "$OUT" | cut -f1))"
