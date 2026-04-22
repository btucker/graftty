# GrafttyMobile

The iOS app that attaches to a running Graftty server over Tailscale
using the existing `/sessions` + `/ws` WebSocket protocol.

## Generating / regenerating the Xcode project

```sh
brew install xcodegen   # one-time
cd Apps/GrafttyMobile
xcodegen generate
```

The generated `GrafttyMobile.xcodeproj` is committed so teammates
without xcodegen can still `xcodebuild` or open it in Xcode.

## Building

```sh
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -destination 'generic/platform=iOS Simulator' \
  build
```

Or open `GrafttyMobile.xcodeproj` in Xcode and ⌘R.

## Running

1. On your Mac, launch Graftty → Settings → enable Web Access → "Show QR code".
2. In the iOS simulator or on a tailnet iPhone/iPad, launch GrafttyMobile.
3. Grant Face ID. Tap +, scan the QR (or enter URL manually), pick a session.

## Where the code lives

- Business logic: `Sources/GrafttyMobileKit/` (SwiftPM library, all files
  wrapped in `#if canImport(UIKit)` so `swift build` on macOS still passes).
- App bundle metadata: this directory.
