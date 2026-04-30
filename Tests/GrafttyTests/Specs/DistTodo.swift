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
@spec DIST-1.2: While the `GRAFTTY_VERSION` environment variable is set, the build script shall write that value into both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
""", .disabled("not yet implemented"))
    func dist_1_2() async throws { }

    @Test("""
@spec DIST-1.3: If the `GRAFTTY_VERSION` environment variable is not set, then the build script shall use `0.0.0-dev` as the default version.
""", .disabled("not yet implemented"))
    func dist_1_3() async throws { }

    @Test("""
@spec DIST-1.4: The build script shall ad-hoc codesign every Mach-O in the bundle in inner-to-outer order: `Contents/Helpers/zmx`, `Contents/Helpers/graftty`, `Contents/MacOS/Graftty`, then the bundle itself, and shall verify the resulting signature with `codesign --verify --strict`.
""", .disabled("not yet implemented"))
    func dist_1_4() async throws { }

    @Test("""
@spec DIST-2.1: When a git tag matching `v*` is pushed to origin, the GitHub Actions workflow `.github/workflows/release.yml` shall build the app bundle in release configuration, verify codesigning, zip the bundle as `Graftty-<version>.zip`, ensure a GitHub release tagged `v<version>` has the zip attached, and ensure the `btucker/homebrew-graftty` cask reflects the new version and sha256.
""", .disabled("not yet implemented"))
    func dist_2_1() async throws { }

    @Test("""
@spec DIST-2.2: If the pushed tag does not start with `v`, then the release workflow shall fail before building.
""", .disabled("not yet implemented"))
    func dist_2_2() async throws { }

    @Test("""
@spec DIST-2.3: If a release for the pushed tag already exists, then the workflow shall re-upload the zip with `--clobber` and continue to the cask update step rather than failing.
""", .disabled("not yet implemented"))
    func dist_2_3() async throws { }

    @Test("""
@spec DIST-2.4: The release zip shall be produced with `ditto -c -k --keepParent` (not `zip`) so that codesign-relevant extended attributes survive — `zip` strips them and installs fail with opaque "damaged" errors after reboot.
""", .disabled("not yet implemented"))
    func dist_2_4() async throws { }

    @Test("""
@spec DIST-3.1: The Homebrew tap `btucker/homebrew-graftty` shall expose a cask `graftty` that downloads the release zip, installs `Graftty.app` to `/Applications`, and symlinks `Graftty.app/Contents/Helpers/graftty` onto the user's PATH as `graftty`.
""", .disabled("not yet implemented"))
    func dist_3_1() async throws { }

    @Test("""
@spec DIST-3.2: While the application is ad-hoc signed (not Developer ID notarized), the cask shall display a `caveats` notice explaining that macOS will refuse to open the app on first launch and providing the steps to bypass Gatekeeper.
""", .disabled("not yet implemented"))
    func dist_3_2() async throws { }

    @Test("""
@spec DIST-3.3: When the user runs `brew uninstall --cask --zap graftty`, the cask shall remove `~/Library/Application Support/Graftty`, `~/Library/Preferences/com.graftty.app.plist`, and `~/Library/Caches/com.graftty.app`.
""", .disabled("not yet implemented"))
    func dist_3_3() async throws { }
}
