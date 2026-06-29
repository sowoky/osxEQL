#!/bin/bash
# build-dmg.sh — wrap dist/osxEQL.app into a distributable, compressed DMG.
# Produces dist/osxEQL-<version>.dmg with a drag-to-Applications layout and a
# short first-open note (the app is unsigned — users right-click → Open once).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$REPO/dist/osxEQL.app"
[ -d "$APP" ] || { echo "no $APP — run packaging/build-app.sh first"; exit 1; }

VER="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)"
STAGE="$(mktemp -d)/osxEQL"
DMG="$REPO/dist/osxEQL-$VER.dmg"

mkdir -p "$STAGE"
ditto "$APP" "$STAGE/osxEQL.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
osxEQL — EverQuest Legends on Apple Silicon (open-source Wine + DXMT)

1. Drag osxEQL onto the Applications folder (shown here).
2. The app is not signed by Apple, so the FIRST time you open it:
   right-click (Control-click) osxEQL in Applications → Open → Open.
   (If macOS still blocks it: System Settings → Privacy & Security →
    scroll down → "Open Anyway".)
3. On first launch osxEQL asks for EQLegends_setup.exe — download that from
   the official EverQuest Legends site first (you need a Daybreak account).
   osxEQL installs it, then opens the launcher so you can log in and download
   the game. The game (~7 GB+) downloads through the launcher, not from us.

EverQuest Legends is Daybreak's game and is NOT included. This is an
unofficial fan-made compatibility tool. See the GitHub page for details.
TXT

echo "building $DMG"
rm -f "$DMG"
hdiutil create -volname "osxEQL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "built: $DMG  ($(du -sh "$DMG" | cut -f1))"
