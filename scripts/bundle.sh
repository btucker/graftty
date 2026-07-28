#!/bin/bash
# Package the Graftty app + CLI into a proper macOS .app bundle.
#
# Output: .build/Graftty.app/
#   Contents/
#     Info.plist
#     Frameworks/
#       Sparkle.framework
#     MacOS/
#       Graftty    (the SwiftUI app)
#     Helpers/
#       graftty    (the CLI, renamed from graftty-cli per ATTN-1.1)
#
# Usage:
#   ./scripts/bundle.sh            # build bundle only
#   ./scripts/bundle.sh install    # build, then ditto into /Applications/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

INSTALL=0
if [[ "${1:-}" == "install" ]]; then
  INSTALL=1
  shift
fi

CONFIGURATION="${CONFIGURATION:-debug}"
GRAFTTY_VERSION="${GRAFTTY_VERSION:-0.0.0-dev}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
# CODESIGN_IDENTITY="-" → ad-hoc (default; works for local dev without an
# Apple Developer cert). Set to "Developer ID Application: …" in CI to
# produce a notarizable bundle. When non-ad-hoc, we additionally enable
# hardened runtime and a secure timestamp, both required by notarytool.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [[ ! "$GRAFTTY_VERSION" =~ ^[A-Za-z0-9._+-]+$ ]]; then
  echo "GRAFTTY_VERSION must match [A-Za-z0-9._+-]+ (got '$GRAFTTY_VERSION')" >&2
  exit 1
fi
if [[ "$SPARKLE_PUBLIC_ED_KEY" == "__SPARKLE_PUBLIC_ED_KEY__" ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY is still the placeholder sentinel" >&2
  exit 1
fi
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" && ! "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/=]+$ ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY must be a base64 EdDSA public key" >&2
  exit 1
fi
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  SPARKLE_PUBLIC_ED_KEY_BYTES="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d '[:space:]')"
  if [[ "$SPARKLE_PUBLIC_ED_KEY_BYTES" != "32" ]]; then
    echo "SPARKLE_PUBLIC_ED_KEY must decode to a 32-byte EdDSA public key" >&2
    exit 1
  fi
fi
if [[ "$CONFIGURATION" == "release" && -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY must be set for release builds" >&2
  exit 1
fi
if [[ "$CONFIGURATION" == "release" && -z "$SPARKLE_FEED_URL" ]]; then
  SPARKLE_FEED_URL="https://raw.githubusercontent.com/btucker/graftty/main/appcast.xml"
fi

echo "→ GRAFTTY_VERSION=$GRAFTTY_VERSION"
echo "→ swift build --configuration $CONFIGURATION"
swift build --configuration "$CONFIGURATION"

BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP="$REPO/.build/Graftty.app"

echo "→ rm -rf $APP && mkdir bundle dirs"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

echo "→ copy binaries"
# The main app binary goes in Contents/MacOS/ per Apple convention.
# The CLI lives in Contents/Helpers/ to avoid the case-insensitive filesystem
# collision that happens when both "Graftty" and "graftty" sit in the same
# directory (APFS treats them as the same filename).
cp "$BIN_DIR/Graftty" "$APP/Contents/MacOS/Graftty"
cp "$BIN_DIR/graftty-cli" "$APP/Contents/Helpers/graftty"

echo "→ copy dynamic frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# WebRTC ships as a binary XCFramework via stasel/WebRTC. The Mac
# binary links it (the iPad-pairing path on GrafttyKit). Without this
# copy the app dies on launch with `Library not loaded:
# @rpath/WebRTC.framework/WebRTC` — how v0.1.5 shipped broken.
ditto "$BIN_DIR/WebRTC.framework" "$APP/Contents/Frameworks/WebRTC.framework"

FRAMEWORK_RPATH="@executable_path/../Frameworks"
for executable in "$APP/Contents/MacOS/Graftty" "$APP/Contents/Helpers/graftty"; do
  if ! otool -l "$executable" | grep -q "$FRAMEWORK_RPATH"; then
    install_name_tool -add_rpath "$FRAMEWORK_RPATH" "$executable"
  fi
done

# Copy SwiftPM resource bundles into Contents/Resources/ (Apple's required
# layout — a foreign item at the .app root would fail `codesign --strict`).
# NOTE: SwiftPM's generated `Bundle.module` accessor does NOT probe
# Contents/Resources — it only checks the .app root and the compiling
# machine's .build path, so it traps here at runtime (the v0.1.10 launch
# crash). GrafttyKitResourceBundle.resolve() (CONFIG-2.6) bridges the gap by
# locating the bundle under Contents/Resources first; this copy is what it
# finds. Do not "simplify" by dropping either side.
for b in "$BIN_DIR"/*_GrafttyKit.bundle "$BIN_DIR"/*_GrafttyCLI.bundle; do
    [[ -e "$b" ]] || continue
    cp -R "$b" "$APP/Contents/Resources/$(basename "$b")"
done

echo "→ install bundled zmx"
# zmx is the per-pane PTY child for every Graftty terminal, providing
# session persistence so shells survive app quits. The binary is vendored
# at Resources/zmx-binary/zmx; bundle.sh just copies it into Helpers/.
cp "$REPO/Resources/zmx-binary/zmx" "$APP/Contents/Helpers/zmx"
chmod +x "$APP/Contents/Helpers/zmx"

echo "→ build + copy app icon"
"$SCRIPT_DIR/build-icon.sh" "$APP/Contents/Resources/AppIcon.icns"

SPARKLE_PUBLIC_ED_KEY_PLIST=""
if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  SPARKLE_PUBLIC_ED_KEY_PLIST="    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_ED_KEY</string>"
fi
SPARKLE_FEED_URL_PLIST=""
if [[ -n "$SPARKLE_FEED_URL" ]]; then
  SPARKLE_FEED_URL_PLIST="    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>"
fi

echo "→ write Info.plist"
# NOTE: heredoc is unquoted so $GRAFTTY_VERSION expands.
# Any other $ or backticks added below will also expand — keep
# this body to literal XML plus the substitutions above.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Graftty</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.graftty.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Graftty</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$GRAFTTY_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$GRAFTTY_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/btucker/graftty/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>CE9gods92d0ACzxxj85iTEaMxeF/kdJNjKRBdoLaOFY=</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Graftty uses the local network to discover and connect to your other Macs.</string>
    <key>NSBonjourServices</key>
    <array>
      <string>_graftty._tcp</string>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
      <key>NSAllowsLocalNetworking</key>
      <true/>
    </dict>
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key>
        <string>com.graftty.app.worktree</string>
        <key>CFBundleURLSchemes</key>
        <array>
          <string>graftty</string>
        </array>
      </dict>
    </array>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign helpers first, then the main binary, then the bundle itself.
# Apple's nesting rules require nested code to already be signed when
# the outer container is signed; otherwise the outer signature does
# not cover them and the runtime rejects the bundle.
ENTITLEMENTS_FILE="$SCRIPT_DIR/entitlements/Graftty.entitlements"
SIGN_OPTS=(--force --sign "$CODESIGN_IDENTITY")
# `${VAR:+$VAR}` (not an array) avoids the bash-3.2 unbound-array splat
# bug when the variable is empty; this stays single-token-safe because
# --preserve-metadata=... has no internal whitespace.
SPARKLE_PRESERVE=""
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  echo "→ codesign with Developer ID: $CODESIGN_IDENTITY (inner → outer)"
  SIGN_OPTS+=(--options runtime --timestamp)
  # Sparkle ships Downloader/Installer XPC services with sandbox + network/admin
  # entitlements that we must keep when re-signing.
  SPARKLE_PRESERVE="--preserve-metadata=entitlements,requirements,flags"
else
  echo "→ ad-hoc codesign (inner → outer)"
fi
codesign "${SIGN_OPTS[@]}" ${SPARKLE_PRESERVE:+$SPARKLE_PRESERVE} "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_OPTS[@]}" ${SPARKLE_PRESERVE:+$SPARKLE_PRESERVE} "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_OPTS[@]}" ${SPARKLE_PRESERVE:+$SPARKLE_PRESERVE} "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign "${SIGN_OPTS[@]}" ${SPARKLE_PRESERVE:+$SPARKLE_PRESERVE} "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign "${SIGN_OPTS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_OPTS[@]}" "$APP/Contents/Frameworks/WebRTC.framework"
codesign "${SIGN_OPTS[@]}" "$APP/Contents/Helpers/zmx"
codesign "${SIGN_OPTS[@]}" "$APP/Contents/Helpers/graftty"
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS_FILE" "$APP/Contents/MacOS/Graftty"
codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS_FILE" "$APP"
codesign --verify --strict "$APP"

echo "→ verify dynamic framework linkage"
test -e "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
test -e "$APP/Contents/Frameworks/WebRTC.framework/Versions/A/WebRTC"
for executable in "$APP/Contents/MacOS/Graftty" "$APP/Contents/Helpers/graftty"; do
  otool -l "$executable" | grep -q "$FRAMEWORK_RPATH"
done

echo "✓ Bundle at $APP"
echo "  Run:  open '$APP'"
echo "  CLI:  '$APP/Contents/Helpers/graftty' notify 'hello'"

if [[ "$INSTALL" == "1" ]]; then
  DEST="/Applications/Graftty.app"
  echo "→ install to $DEST"

  # Kill any running instance first — mach-o refuses to be replaced while
  # executing, and silent partial replacement would leave the user with a
  # half-updated app.
  if pgrep -x Graftty >/dev/null 2>&1; then
    echo "  (stopping running Graftty first)"
    osascript -e 'tell application "Graftty" to quit' 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      pgrep -x Graftty >/dev/null 2>&1 || break
      sleep 1
    done
    pkill -x Graftty 2>/dev/null || true
  fi

  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "✓ Installed at $DEST"
fi
