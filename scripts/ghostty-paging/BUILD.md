# Paging dependency builds

Mac and GrafttyMobile development, CI, and release builds use the published
`btucker/libghostty-spm` revision in `Package.swift` and `Package.resolved`.
Paging is enabled for all Apple builds. The Mac and mobile test suites require
paging support, so a missing capability fails instead of silently skipping the
native checkpoint tests. Existing zmx daemons without paging still use the
runtime legacy attachment protocol until their sessions restart.

The dependency fork owns engine and wrapper sources, the native patch recipe,
all five architecture slices, probes, immutable binary releases, and provenance.
See [the package build instructions](https://github.com/btucker/libghostty-spm/tree/3.0.2026102901/Paging).
Graftty no longer builds a replacement package during CI or release bundling.

## Develop the dependency locally

Start a separate libghostty-spm checkout at the revision in Graftty’s `Package.resolved`.
Build it with its `./build.sh` using the pinned
Zig compiler and Xcode. That writes `BinaryTarget/GhosttyKit.xcframework` and
`PAGING-BUILD.json`. Verify it with `python3 Paging/provenance.py verify`.
Do not modify Graftty's shared `.dependencies/libghostty-spm` output.

Copy `Package.local.swift` to `Package.swift` in that dependency checkout so it
selects the verified local binary. Then select the checkout explicitly:

```sh
GRAFTTY_GHOSTTY_PACKAGE_PATH=/absolute/path/to/libghostty-spm scripts/swiftpm test
```

The manifest validates the dependency's own receipt against its native recipe,
Swift sources, and binary files. Graftty does not maintain a second patch recipe.
An absent or empty override uses the published package. Auto-discovered packages
are ignored with a diagnostic. Local dependency changes require a refreshed
receipt as described by the dependency, and native changes require rebuilt
binaries. Use a fresh output path for Xcode if its manifest cache retains an
older local package selection.

The shared SwiftPM wrapper and bundle script reevaluate the manifest and pass
a renderer-specific compiler context to app and dependency targets. For Xcode,
launch it with the override in its environment and resolve packages again.
Command-line Xcode builds should forward the same context:

```sh
export GRAFTTY_GHOSTTY_PACKAGE_PATH=/absolute/path/to/libghostty-spm
renderer_context="$(python3 scripts/ghostty-paging/compiler-context.py "$PWD" "$PWD/.build")"
xcodebuild -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile -destination 'generic/platform=iOS Simulator' \
  "OTHER_SWIFT_FLAGS=\$(inherited) -Xcc $renderer_context" build
```

Run the dependency's packaged AppKit/UIKit probes and native link-click tests
against the exact released archives before changing the app pin. For Graftty's
opt-in `EDITOR-1.10` test, set `GRAFTTY_LINK_CLICK_TEST_DIR` to the artifact
directory printed by the dependency's `Paging/test-link-clicks.sh`.
