#!/usr/bin/env bash
#
# Build the AirlockCompanion menubar app.
#
# Steps:
#   1. `swift build -c release --arch arm64 --arch x86_64` → universal binary
#   2. Wrap into a .app bundle at ./build/AirlockCompanion.app  so LSUIElement
#      and Bonjour permissions are applied.
#
# Requires: Swift 5.9+. Universal (multi-arch) builds go through XCBuild and
# need a full Xcode install; with only the command-line tools, or for a
# faster local build, build for one arch:  ARCHS=arm64 ./build.sh

set -euo pipefail

# Portable "cd to this script's directory" — no readlink -f (BSD/macOS quirk).
cd "$(dirname "$0")"

ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

echo ">>> swift build (release, $ARCHS)"
swift build -c release "${ARCH_FLAGS[@]}"
# The output dir depends on arch count and toolchain (.build/release,
# .build/apple/Products/Release, .build/out/Products/Release, …) — ask.
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/AirlockCompanion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 0755 "$BIN_DIR/AirlockCompanion"   "$APP/Contents/MacOS/AirlockCompanion"
install -m 0644 Info.plist                       "$APP/Contents/Info.plist"
install -m 0644 assets/AppIcon.icns              "$APP/Contents/Resources/AppIcon.icns"

# PkgInfo tells the Finder this is an app.
printf '%s' 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc code signature (`-s -`). Without ANY signature, macOS Sequoia
# rejects downloaded copies with "damaged and can't be opened" and no
# longer offers a right-click Open bypass. An ad-hoc signature isn't
# trusted by Gatekeeper (still triggers the first-launch prompt), but
# it satisfies the codesign integrity check so the prompt is passable
# via right-click Open OR by stripping the quarantine xattr.
#
# The bundle has no nested code (frameworks, helpers), so signing the
# bundle itself covers the main executable — no deprecated `--deep`.
# When we eventually get an Apple Developer ID, swap `-` for the
# team identity and add `--options runtime` for notarization.
echo ">>> codesign (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo
echo "Built: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/AirlockCompanion"))"
echo "Run:   open '$(pwd)/$APP'"
echo "or:    swift run   # unbundled: no notifications (logged to stderr instead)"
