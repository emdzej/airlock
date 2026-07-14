#!/usr/bin/env bash
#
# Wrap build/AirlockCompanion.app into a DMG for distribution.
#
# Requires: `build.sh` to have run first (so build/AirlockCompanion.app
# exists). Output: build/AirlockCompanion-<version>.dmg
#
# The DMG is unsigned — first-launch on other Macs will need
# "right-click → Open" to bypass Gatekeeper. Signing / notarization
# is a follow-up (needs an Apple Developer Account).

set -euo pipefail

cd "$(dirname "$0")"

APP="build/AirlockCompanion.app"
if [ ! -d "$APP" ]; then
    echo "$APP not found. Run ./build.sh first." >&2
    exit 1
fi

# Pull version from Info.plist (CFBundleShortVersionString).
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"

DMG_STAGE="build/dmg-stage"
DMG_OUT="build/AirlockCompanion-${VERSION}.dmg"

# Clean previous stage.
rm -rf "$DMG_STAGE" "$DMG_OUT"
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

rm -rf "$DMG_STAGE"

echo
echo "DMG ready: $(pwd)/$DMG_OUT"
echo "Size: $(du -h "$DMG_OUT" | cut -f1)"
echo
echo "First-run on another Mac: right-click → Open (Gatekeeper)."
echo "Once run once, macOS remembers; subsequent launches work normally."
