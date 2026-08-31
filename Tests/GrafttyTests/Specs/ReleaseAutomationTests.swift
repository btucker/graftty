import Foundation
import Testing

@Suite("Release automation")
struct ReleaseAutomationTests {
    @Test("""
    @spec DIST-1.2: While the `GRAFTTY_VERSION` and `GRAFTTY_BUILD_VERSION` environment variables are set, the build script shall write the release version into `CFBundleShortVersionString` and the numeric build version into `CFBundleVersion` in `Info.plist`.
    """)
    func bundleWritesDisplayAndBuildVersionsSeparately() throws {
        let script = try Self.contents(of: "scripts/bundle.sh")

        #expect(script.contains("<key>CFBundleShortVersionString</key>\n    <string>$GRAFTTY_VERSION</string>"))
        #expect(script.contains("<key>CFBundleVersion</key>\n    <string>$GRAFTTY_BUILD_VERSION</string>"))
    }

    @Test("""
    @spec DIST-2.1: When a git tag containing valid SemVer after its leading `v` is pushed to origin, the GitHub Actions workflow `.github/workflows/release.yml` shall build the app bundle in release configuration, verify codesigning, zip the bundle as `Graftty-<version>.zip`, ensure a GitHub release tagged `v<version>` has the zip attached, and, for stable versions, ensure the `btucker/homebrew-graftty` cask reflects the new version and sha256.
    """)
    func taggedWorkflowPublishesArtifactsAndStableCaskUpdates() throws {
        let workflow = try Self.contents(of: ".github/workflows/release.yml")

        #expect(workflow.contains("tags: ['v*']"))
        #expect(workflow.contains("CONFIGURATION: release"))
        #expect(workflow.contains("codesign --verify --strict --verbose=2 .build/Graftty.app"))
        #expect(workflow.contains(#"ZIP="Graftty-$VERSION.zip""#))
        #expect(workflow.contains(#"gh release upload "v$VERSION" "$ZIP" --clobber"#))
        #expect(workflow.contains("- name: Update Homebrew tap\n        if: steps.version.outputs.prerelease != 'true'"))
    }

    @Test("""
    @spec DIST-2.2: If a pushed release tag does not contain valid SemVer after its leading `v`, then the release workflow shall fail before building.
    """)
    func invalidSemVerTagFailsBeforeBuild() throws {
        let workflow = try Self.contents(of: ".github/workflows/release.yml")
        let metadataValidation = try #require(
            workflow.range(of: "scripts/release-metadata.sh")
        )
        let buildStep = try #require(workflow.range(of: "- name: Build app bundle"))
        #expect(metadataValidation.lowerBound < buildStep.lowerBound)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            Self.repositoryRoot.appendingPathComponent("scripts/release-metadata.sh").path,
            "next",
            "1",
            "1",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
    }

    @Test("""
    @spec DIST-2.3: If a release for the pushed tag already exists, then the workflow shall re-upload the zip with `--clobber` and continue to the cask update step for stable versions rather than failing.
    """)
    func existingReleaseIsClobberedBeforeStableCaskUpdate() throws {
        let workflow = try Self.contents(of: ".github/workflows/release.yml")
        let existingReleaseCheck = try #require(
            workflow.range(of: #"if gh release view "v$VERSION" >/dev/null 2>&1; then"#)
        )
        let clobberUpload = try #require(
            workflow.range(of: #"gh release upload "v$VERSION" "$ZIP" --clobber"#)
        )
        let stableCaskStep = try #require(
            workflow.range(of: "- name: Update Homebrew tap\n        if: steps.version.outputs.prerelease != 'true'")
        )

        #expect(existingReleaseCheck.lowerBound < clobberUpload.lowerBound)
        #expect(clobberUpload.lowerBound < stableCaskStep.lowerBound)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
