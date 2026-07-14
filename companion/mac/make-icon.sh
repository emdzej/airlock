#!/usr/bin/env bash
#
# Regenerate assets/AppIcon.icns from assets/AppIcon.svg.
#
# The .icns is checked into git so that build.sh + CI don't need
# librsvg installed. Re-run this locally after editing AppIcon.svg
# and commit both files together.
#
# Requires:
#   - librsvg  (brew install librsvg)   → rsvg-convert
#   - iconutil (bundled with Xcode CLTs)

set -euo pipefail
cd "$(dirname "$0")"

SVG=assets/AppIcon.svg
OUT=assets/AppIcon.icns
STAGE=assets/AppIcon.iconset

if [ ! -f "$SVG" ]; then
    echo "Missing $SVG" >&2
    exit 1
fi
if ! command -v rsvg-convert >/dev/null; then
    echo "rsvg-convert not found. Install with: brew install librsvg" >&2
    exit 1
fi

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"

# Standard iconset sizes for Finder / Dock / Launchpad / Info window.
# iconutil expects exactly these names.
for base in 16 32 128 256 512; do
    x1=$base
    x2=$((base * 2))
    rsvg-convert -w "$x1" -h "$x1" "$SVG" -o "$STAGE/icon_${base}x${base}.png"
    rsvg-convert -w "$x2" -h "$x2" "$SVG" -o "$STAGE/icon_${base}x${base}@2x.png"
done

iconutil -c icns "$STAGE" -o "$OUT"
rm -rf "$STAGE"

echo "Generated: $OUT ($(du -h "$OUT" | cut -f1))"
