// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("DIST — pending specs")
struct DistTodo {
    @Test("""
@spec DIST-1.1: The build script (`scripts/bundle.sh`) shall produce a self-contained `Graftty.app` bundle in `.build/` containing the SwiftUI application binary at `Contents/MacOS/Graftty`, the CLI helper at `Contents/Helpers/graftty`, and the bundled `zmx` binary at `Contents/Helpers/zmx`.
""", .disabled("not yet implemented"))
    func dist_1_1() async throws { }

    @Test("""
@spec DIST-1.3: If the `GRAFTTY_VERSION` environment variable is not set, then the build script shall use `0.0.0-dev` as the default version.
""", .disabled("not yet implemented"))
    func dist_1_3() async throws { }

    @Test("""
@spec DIST-1.4: The build script shall codesign every Mach-O in the bundle in inner-to-outer order: `Contents/Helpers/zmx`, `Contents/Helpers/graftty`, `Contents/MacOS/Graftty`, then the bundle itself, and shall verify the resulting signature with `codesign --verify --strict`. The signing identity is chosen by the `CODESIGN_IDENTITY` environment variable (defaulting to `-` for ad-hoc); when set to a Developer ID Application identity, the script shall additionally enable hardened runtime (`--options runtime`), secure timestamping (`--timestamp`), and apply `scripts/entitlements/Graftty.entitlements` to the main executable.
""", .disabled("not yet implemented"))
    func dist_1_4() async throws { }

    @Test("""
@spec DIST-2.4: The release zip shall be produced with `ditto -c -k --keepParent` (not `zip`) so that codesign-relevant extended attributes survive — `zip` strips them and installs fail with opaque "damaged" errors after reboot.
""", .disabled("not yet implemented"))
    func dist_2_4() async throws { }

    @Test("""
@spec DIST-3.1: The Homebrew tap `btucker/homebrew-graftty` shall expose a cask `graftty` that downloads the release zip, installs `Graftty.app` to `/Applications`, and symlinks `Graftty.app/Contents/Helpers/graftty` onto the user's PATH as `graftty`.
""", .disabled("not yet implemented"))
    func dist_3_1() async throws { }

    @Test("""
@spec DIST-3.3: When the user runs `brew uninstall --cask --zap graftty`, the cask shall remove `~/Library/Application Support/Graftty`, `~/Library/Preferences/com.graftty.app.plist`, and `~/Library/Caches/com.graftty.app`.
""", .disabled("not yet implemented"))
    func dist_3_3() async throws { }

    @Test("""
@spec DIST-3.4: When a tagged release is built in CI, the release workflow shall sign the bundle with the `Developer ID Application: Quotably, LLC (67APXH3J92)` identity, submit it to `xcrun notarytool` using App Store Connect API key credentials, and on success staple the notarization ticket into the bundle with `xcrun stapler staple` before zipping for distribution.
""", .disabled("not yet implemented"))
    func dist_3_4() async throws { }
}
