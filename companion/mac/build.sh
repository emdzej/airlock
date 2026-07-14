#!/usr/bin/env bash
#
# Build the AirlockCompanion menubar app.
#
# Steps:
#   1. `swift build -c release`  → CLI binary at .build/release/AirlockCompanion
#   2. Wrap into a .app bundle at ./build/AirlockCompanion.app  so LSUIElement
#      and Bonjour permissions are applied.
#
# Requires: Xcode command-line tools (`xcode-select --install`) and Swift 5.9+.

set -euo pipefail

# Portable "cd to this script's directory" — no readlink -f (BSD/macOS quirk).
cd "$(dirname "$0")"

echo ">>> swift build (release)"
swift build -c release

APP="build/AirlockCompanion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 0755 .build/release/AirlockCompanion "$APP/Contents/MacOS/AirlockCompanion"
install -m 0644 Info.plist                       "$APP/Contents/Info.plist"

# PkgInfo tells the Finder this is an app.
printf '%s' 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc code signature (`-s -`). Without ANY signature, macOS Sequoia
# rejects downloaded copies with "damaged and can't be opened" and no
# longer offers a right-click Open bypass. An ad-hoc signature isn't
# trusted by Gatekeeper (still triggers the first-launch prompt), but
# it satisfies the codesign integrity check so the prompt is passable
# via right-click Open OR by stripping the quarantine xattr.
#
# When we eventually get an Apple Developer ID, swap `-` for the
# team identity and add `--options runtime` for notarization.
echo ">>> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo
echo "Built: $(pwd)/$APP"
echo "Run:   open '$(pwd)/$APP'"
echo "or:    swift run   # bypasses the bundle; skips LSUIElement so Dock shows up"
