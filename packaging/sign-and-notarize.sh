#!/bin/bash
# sign-and-notarize.sh — sign an assembled osxEQL.app with a Developer ID and
# optionally notarize + staple it for Gatekeeper-clean distribution.
#
# Usage:
#   packaging/sign-and-notarize.sh [dist/osxEQL.app]
#   packaging/sign-and-notarize.sh --notarize [dist/osxEQL.app]
#
# Environment (secrets — NEVER commit these):
#   CODESIGN_IDENTITY   Developer ID Application identity (required)
#                       e.g. "Developer ID Application: SKYBOUND SOLUTIONS, LLC (WC298LM6JQ)"
#   NOTARIZE_KEY        Path to App Store Connect API .p8 key file (for --notarize)
#   NOTARIZE_KEY_ID     API key ID (for --notarize)
#   NOTARIZE_ISSUER     API issuer UUID (for --notarize)
#
# Without --notarize the script just signs (useful for local testing).
# With --notarize it submits to Apple, waits, and staples the ticket.
#
# Why this exists: macOS 26 (Tahoe) introduced SIP-protected provenance tracking
# that breaks the old xattr -dr workaround for ad-hoc signed apps. A Developer ID
# signature + notarization is now required for Gatekeeper to allow the app.
#
# Wine is special: notarization requires hardened runtime, but hardened runtime
# blocks Wine from mapping Windows PE binaries. The entitlements.plist in this
# directory grants the 4 exceptions Wine needs (same as CrossOver).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENT="$HERE/entitlements.plist"
NOTARIZE=false

# --- parse args ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize) NOTARIZE=true; shift ;;
        *)          APP="$1"; shift ;;
    esac
done
APP="${APP:-$(cd "$HERE/.." && pwd)/dist/osxEQL.app}"

# --- preflight ----------------------------------------------------------------
[ -d "$APP" ]           || { echo "error: no app at $APP"; exit 1; }
[ -f "$ENT" ]           || { echo "error: missing $ENT"; exit 1; }
[ -n "${CODESIGN_IDENTITY:-}" ] || { echo "error: set CODESIGN_IDENTITY"; exit 1; }
if $NOTARIZE; then
    [ -n "${NOTARIZE_KEY:-}" ]    || { echo "error: set NOTARIZE_KEY (path to .p8)"; exit 1; }
    [ -n "${NOTARIZE_KEY_ID:-}" ] || { echo "error: set NOTARIZE_KEY_ID"; exit 1; }
    [ -n "${NOTARIZE_ISSUER:-}" ] || { echo "error: set NOTARIZE_ISSUER"; exit 1; }
    [ -f "$NOTARIZE_KEY" ]        || { echo "error: key file not found: $NOTARIZE_KEY"; exit 1; }
fi

WINE="$APP/Contents/Resources/Wine"
[ -d "$WINE" ] || { echo "error: no Wine runtime at $WINE"; exit 1; }

echo "=== sign-and-notarize ==="
echo "app:      $APP"
echo "identity: $CODESIGN_IDENTITY"
echo "notarize: $NOTARIZE"
echo ""

# --- 1. sign all Mach-O .so and .dylib inside Wine/ --------------------------
echo "signing Wine libraries…"
COUNT=0
while IFS= read -r -d '' f; do
    # only sign actual Mach-O files (skip PE .dll files and text files)
    if file "$f" | grep -qi "mach-o"; then
        codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$f" 2>/dev/null
        COUNT=$((COUNT + 1))
    fi
done < <(find "$WINE" -type f \( -name "*.so" -o -name "*.dylib" \) -print0)
echo "  signed $COUNT libraries"

# --- 2. sign Wine executables WITH entitlements + hardened runtime -------------
echo "signing Wine executables (hardened runtime + entitlements)…"
for bin in \
    "$WINE/lib/wine/x86_64-unix/wine" \
    "$WINE/bin/wine" \
    "$WINE/bin/wineserver"; do
    if [ -f "$bin" ]; then
        codesign --force --sign "$CODESIGN_IDENTITY" --timestamp --options runtime \
            --entitlements "$ENT" "$bin"
        echo "  signed $(basename "$bin")"
    fi
done

# --- 3. sign the progress helper (hardened runtime, no special entitlements) ---
PROGRESS="$APP/Contents/Resources/osxeql-progress"
if [ -f "$PROGRESS" ]; then
    echo "signing osxeql-progress…"
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp --options runtime "$PROGRESS"
fi

# --- 4. sign the top-level app bundle ----------------------------------------
echo "signing app bundle…"
codesign --force --deep --sign "$CODESIGN_IDENTITY" --timestamp --options runtime \
    --entitlements "$ENT" "$APP"

# --- 5. verify ----------------------------------------------------------------
echo "verifying…"
codesign --verify --deep --strict "$APP" || { echo "FAIL: signature verification"; exit 1; }
echo "  signature OK"

if ! $NOTARIZE; then
    echo ""
    echo "done (signed, not notarized). To notarize, re-run with --notarize."
    exit 0
fi

# --- 6. notarize --------------------------------------------------------------
echo ""
echo "submitting for notarization…"
ZIP="$(mktemp -d)/osxEQL.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --key "$NOTARIZE_KEY" \
    --key-id "$NOTARIZE_KEY_ID" \
    --issuer "$NOTARIZE_ISSUER" \
    --wait \
    || { echo "FAIL: notarization rejected — run 'xcrun notarytool log' for details"; rm -f "$ZIP"; exit 1; }
rm -f "$ZIP"

# --- 7. staple ----------------------------------------------------------------
echo "stapling…"
xcrun stapler staple "$APP" || { echo "FAIL: staple"; exit 1; }

# --- 8. final check -----------------------------------------------------------
echo ""
echo "=== verification ==="
spctl -a -v "$APP" 2>&1
echo ""
echo "done. App is signed, notarized, and stapled."
