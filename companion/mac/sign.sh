#!/usr/bin/env bash
#
# Sign build/AirlockCompanion.app with the Developer ID, then notarise and
# staple it, so a downloaded copy opens with a double-click (no "damaged",
# no xattr). Run after build.sh and before package.sh, which then signs and
# notarises the DMG too. Configuration: see signing.sh.
#
# The bundle has no nested code, so signing the bundle covers the
# executable (never --deep for signing). Hardened runtime and a secure
# timestamp are what notarisation requires; Bonjour, NetFS, notifications
# and SMAppService need no entitlements outside the App Sandbox.
#
# Stapling the .app (not only the DMG) lets a copy dragged out of the DMG
# pass Gatekeeper offline too.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=/dev/null  # signing.sh, linted on its own
source ./signing.sh

APP="build/AirlockCompanion.app"
[ -d "$APP" ] || { echo "$APP not found. Run ./build.sh first." >&2; exit 1; }
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application certificate in the keychain (or set SIGN_ID)." >&2; exit 1; }

# Finder info or quarantine attributes make codesign refuse the bundle.
xattr -cr "$APP"

echo ">>> codesign ($SIGN_ID)"
codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"

if [ "${NOTARIZE:-1}" = 0 ]; then
    echo "Signed, not notarised (NOTARIZE=0): $(pwd)/$APP"
    exit 0
fi

echo ">>> notarytool (app)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/AirlockCompanion.zip"
notarize "$TMP/AirlockCompanion.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"
