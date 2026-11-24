#!/bin/bash
# Build AppIcon.icns from Resources/AppIcon.png
#
# Takes the master 1024x1024-or-larger PNG and emits a multi-resolution
# .icns file in the path given by $1 (default: .build/AppIcon.icns).
#
# macOS recognizes these filenames inside the .iconset directory:
#   icon_16x16@2x.png, icon_32x32@2x.png,
#   icon_128x128.png, icon_128x128@2x.png, icon_256x256.png,
#   icon_256x256@2x.png, icon_512x512.png, icon_512x512@2x.png
# The @2x variants are twice the nominal size; iconutil rolls them all
# into a single .icns.
#
# Omit the 1x 16/32 slots: iconutil encodes them as ARGB (ic04/ic05),
# which macOS gives a gray frame at small sizes. The PNG-backed Retina
# slots (ic11/ic12) also serve 1x displays through system downsampling.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO/Resources/AppIcon.png"
OUT="${1:-$REPO/.build/AppIcon.icns}"

if [ ! -f "$SOURCE" ]; then
    echo "✗ Missing $SOURCE" >&2
    exit 1
fi

# Work in a tmp iconset dir; final product goes to $OUT.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
trap "rm -rf \"$(dirname "$ICONSET")\"" EXIT

# name                       size
sizes=(
    "icon_16x16@2x.png        32"
    "icon_32x32@2x.png        64"
    "icon_128x128.png         128"
    "icon_128x128@2x.png      256"
    "icon_256x256.png         256"
    "icon_256x256@2x.png      512"
    "icon_512x512.png         512"
    "icon_512x512@2x.png      1024"
)

for entry in "${sizes[@]}"; do
    name=$(echo "$entry" | awk '{print $1}')
    size=$(echo "$entry" | awk '{print $2}')
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name" > /dev/null
done

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ $OUT"
