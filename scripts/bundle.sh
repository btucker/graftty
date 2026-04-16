#!/bin/bash
# Package the Espalier app + CLI into a proper macOS .app bundle.
#
# Output: .build/Espalier.app/
#   Contents/
#     Info.plist
#     MacOS/
#       Espalier    (the SwiftUI app)
#       espalier    (the CLI, renamed from espalier-cli per ATTN-1.1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

CONFIGURATION="${CONFIGURATION:-debug}"

echo "→ swift build --configuration $CONFIGURATION"
swift build --configuration "$CONFIGURATION"

BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP="$REPO/.build/Espalier.app"

echo "→ rm -rf $APP && mkdir bundle dirs"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"

echo "→ copy binaries"
# The main app binary goes in Contents/MacOS/ per Apple convention.
# The CLI lives in Contents/Helpers/ to avoid the case-insensitive filesystem
# collision that happens when both "Espalier" and "espalier" sit in the same
# directory (APFS treats them as the same filename).
cp "$BIN_DIR/Espalier" "$APP/Contents/MacOS/Espalier"
cp "$BIN_DIR/espalier-cli" "$APP/Contents/Helpers/espalier"

echo "→ write Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Espalier</string>
    <key>CFBundleIdentifier</key>
    <string>com.espalier.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Espalier</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "✓ Bundle at $APP"
echo "  Run:  open '$APP'"
echo "  CLI:  '$APP/Contents/Helpers/espalier' notify 'hello'"
