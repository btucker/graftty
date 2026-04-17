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
ESPALIER_VERSION="${ESPALIER_VERSION:-0.0.0-dev}"
if [[ ! "$ESPALIER_VERSION" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  echo "ESPALIER_VERSION must match [A-Za-z0-9._+-]+ (got '$ESPALIER_VERSION')" >&2
  exit 1
fi

echo "→ ESPALIER_VERSION=$ESPALIER_VERSION"
echo "→ swift build --configuration $CONFIGURATION"
swift build --configuration "$CONFIGURATION"

BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP="$REPO/.build/Espalier.app"

echo "→ rm -rf $APP && mkdir bundle dirs"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

echo "→ copy binaries"
# The main app binary goes in Contents/MacOS/ per Apple convention.
# The CLI lives in Contents/Helpers/ to avoid the case-insensitive filesystem
# collision that happens when both "Espalier" and "espalier" sit in the same
# directory (APFS treats them as the same filename).
cp "$BIN_DIR/Espalier" "$APP/Contents/MacOS/Espalier"
cp "$BIN_DIR/espalier-cli" "$APP/Contents/Helpers/espalier"

echo "→ install bundled zmx"
# zmx is the per-pane PTY child for every Espalier terminal, providing
# session persistence so shells survive app quits. The binary is vendored
# at Resources/zmx-binary/zmx; bundle.sh just copies it into Helpers/.
cp "$REPO/Resources/zmx-binary/zmx" "$APP/Contents/Helpers/zmx"
chmod +x "$APP/Contents/Helpers/zmx"

echo "→ build + copy app icon"
"$SCRIPT_DIR/build-icon.sh" "$APP/Contents/Resources/AppIcon.icns"

echo "→ write Info.plist"
# NOTE: heredoc is unquoted so $ESPALIER_VERSION expands.
# Any other $ or backticks added below will also expand — keep
# this body to literal XML plus that single substitution.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Espalier</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.espalier.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Espalier</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$ESPALIER_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$ESPALIER_VERSION</string>
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

echo "→ ad-hoc codesign (inner → outer)"
# Sign helpers first, then the main binary, then the bundle itself.
# Apple's nesting rules require nested code to already be signed when
# the outer container is signed; otherwise the outer signature does
# not cover them and the runtime rejects the bundle. When we move to
# Developer ID + notarization, this block grows: real identity,
# --options runtime, --timestamp, --entitlements, and a separate
# notarytool/stapler pass after.
codesign --force --sign - "$APP/Contents/Helpers/zmx"
codesign --force --sign - "$APP/Contents/Helpers/espalier"
codesign --force --sign - "$APP/Contents/MacOS/Espalier"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "✓ Bundle at $APP"
echo "  Run:  open '$APP'"
echo "  CLI:  '$APP/Contents/Helpers/espalier' notify 'hello'"
