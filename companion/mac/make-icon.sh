#!/usr/bin/env bash
#
# Regenerate assets/AppIcon.icns from assets/AppIcon-source.png, the
# full-bleed 1024×1024 artwork shared with the iOS app
# (companion/ios/Resources/Assets.xcassets/AppIcon.appiconset).
#
# iOS masks its icons itself; macOS doesn't, so the artwork is clipped
# to Apple's rounded square (824 px body on the 1024 px grid) with a
# soft drop shadow, then rendered at every .icns size.
#
# The .icns is checked into git so that build.sh + CI don't need to run
# this. Re-run it locally after changing the source and commit both.
#
# Requires: Xcode command-line tools (swift, sips, iconutil).

set -euo pipefail
cd "$(dirname "$0")"

SRC=assets/AppIcon-source.png
OUT=assets/AppIcon.icns
[ -f "$SRC" ] || { echo "Missing $SRC" >&2; exit 1; }

# Render into a temp dir and only replace the committed .icns once
# iconutil has succeeded — a failed run leaves the old icon intact.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/shape.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
guard let src = NSImage(contentsOfFile: args[1]) else { fatalError("can't read \(args[1])") }
let size = 1024.0, body = 824.0, radius = 185.4
let rect = NSRect(x: (size - body) / 2, y: (size - body) / 2 + 10, width: body, height: body)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()
path.addClip()
src.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT
swift "$TMP/shape.swift" "$SRC" "$TMP/icon-1024.png"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$TMP/AppIcon.icns"
mv "$TMP/AppIcon.icns" "$OUT"
echo "Wrote $OUT"
