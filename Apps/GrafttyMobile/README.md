# GrafttyMobile

The iOS app for a paired Graftty Mac. It discovers nearby Macs over
Bonjour, verifies and pins the Mac's device identity, then carries terminal
and worktree traffic over mutually authenticated SSH-over-WebRTC channels.
Web Access does not need to be enabled.

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

1. Launch Graftty on a Mac and connect the iPhone/iPad to the same local network.
2. Launch GrafttyMobile, grant Face ID, and tap +.
3. Choose the nearby Mac, compare the verification code on both devices, and
   confirm it on the Mac.
4. Choose a worktree and pane. Subsequent address changes are resolved by the
   Mac's stable paired-device identity.

## Where the code lives

- Business logic: `Sources/GrafttyMobileKit/` (SwiftPM library, all files
  wrapped in `#if canImport(UIKit)` so `swift build` on macOS still passes).
- App bundle metadata: this directory.
