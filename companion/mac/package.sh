#!/usr/bin/env bash
#
# Wrap build/AirlockCompanion.app into a DMG for distribution.
#
# Requires: `build.sh` to have run first (so build/AirlockCompanion.app
# exists). Output: build/AirlockCompanion-<version>.dmg
#
# If sign.sh has signed the app with the Developer ID, the DMG is signed,
# notarised and stapled too (configuration: see signing.sh). Otherwise
# (ad-hoc build) it isn't, and first launch on another Mac needs the
# download's quarantine attribute stripped — see the printed instructions.

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=/dev/null  # signing.sh, linted on its own
source ./signing.sh

APP="build/AirlockCompanion.app"
if [ ! -d "$APP" ]; then
    echo "$APP not found. Run ./build.sh first." >&2
    exit 1
fi

# Pull version from Info.plist (CFBundleShortVersionString). The release
# workflow stamps the tag into Info.plist before build.sh, so a missing
# value means something upstream broke — fail rather than ship a DMG
# with a made-up version.
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    echo "Couldn't read CFBundleShortVersionString from $APP/Contents/Info.plist" >&2
    exit 1
fi

DMG_STAGE="build/dmg-stage"
DMG_OUT="build/AirlockCompanion-${VERSION}.dmg"

# Clean previous stage; always remove it on exit, even on failure.
rm -rf "$DMG_STAGE" "$DMG_OUT"
trap 'rm -rf "$DMG_STAGE"' EXIT
mkdir -p "$DMG_STAGE"

# App + drag-to-install symlink so the DMG opens with an obvious install
# affordance.
cp -a "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

echo ">>> Building $DMG_OUT"
hdiutil create \
    -volname "Airlock Companion" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_OUT" >/dev/null

if has_developer_id "$APP"; then
    echo ">>> codesign DMG ($SIGN_ID)"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG_OUT"
    if [ "${NOTARIZE:-1}" != 0 ]; then
        echo ">>> notarytool (DMG)"
        notarize "$DMG_OUT"
        xcrun stapler staple "$DMG_OUT"
        spctl --assess --type open --context context:primary-signature -vv "$DMG_OUT"
    fi
    SIGNED=1
fi

echo
echo "DMG ready: $(pwd)/$DMG_OUT"
echo "Size: $(du -h "$DMG_OUT" | cut -f1)"
if [ -z "${SIGNED:-}" ]; then
    echo
    echo "Ad-hoc signed (run ./sign.sh before this to sign and notarise)."
    echo "First-run on another Mac:"
    echo "  1. Drag AirlockCompanion.app to /Applications."
    echo "  2. If macOS says the app is 'damaged', run:"
    echo "       xattr -dr com.apple.quarantine /Applications/AirlockCompanion.app"
    echo "  3. Launch it. Subsequent runs work with no prompts."
fi
