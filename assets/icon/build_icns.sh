#!/bin/bash
# build_icns.sh <master_1024.png>  — build AppIcon.icns, install into osxEQL.app, re-sign, refresh.
set -euo pipefail
MASTER="${1:?usage: build_icns.sh <master_1024.png>}"
APP="$HOME/Desktop/osxEQL.app"
WORK="$(dirname "$MASTER")/AppIcon.iconset"
ICNS="$(dirname "$MASTER")/AppIcon.icns"

rm -rf "$WORK"; mkdir -p "$WORK"
# Apple-required iconset members (pt@scale -> px)
gen() { sips -z "$2" "$2" "$MASTER" --out "$WORK/$1" >/dev/null; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
cp "$MASTER" "$WORK/icon_512x512@2x.png"   # 1024 master verbatim
iconutil -c icns "$WORK" -o "$ICNS"
echo "built $ICNS ($(du -h "$ICNS" | cut -f1))"

mkdir -p "$APP/Contents/Resources"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string "AppIcon" "$APP/Contents/Info.plist"
plutil -replace CFBundleIconName -string "AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
echo "installed icon into bundle"

codesign --force --sign - "$APP"
codesign --verify --verbose "$APP" && echo "signature VALID"

# refresh icon caches so Finder/Dock pick it up
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true
echo "done; icon refreshed"
