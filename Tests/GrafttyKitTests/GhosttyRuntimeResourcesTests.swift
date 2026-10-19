import Foundation
import Testing
@testable import GrafttyKit

@Suite("GhosttyRuntimeResources — vendored payload")
struct GhosttyVendoredPayloadTests {
    @Test("""
    @spec CONFIG-2.5: The application bundle shall include ghostty's per-shell integration scripts and the `xterm-ghostty` terminfo entry as vendored resources, pinned to the ghostty version backing libghostty-spm, with upstream license headers preserved and a provenance record, so shell integration works without a separately installed Ghostty.app.
    """)
    func vendoredPayloadShipsInModuleBundle() throws {
        let dir = try #require(GhosttyRuntimeResources.bundledResourcesDir())
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("shell-integration/zsh/.zshenv").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("shell-integration/bash/ghostty.bash").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("PROVENANCE.md").path))
        // terminfo must sit as a SIBLING of the ghostty dir — the layout
        // ZmxSpawnConfiguration.availableGhosttyTerminfoDir (ZMX-6.5) probes.
        let terminfo = dir.deletingLastPathComponent().appendingPathComponent("terminfo")
        #expect(fm.fileExists(atPath: terminfo.appendingPathComponent("78/xterm-ghostty").path))
    }
}

@Suite("GhosttyRuntimeResources.resolve — precedence")
struct GhosttyRuntimeResourcesResolveTests {
    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GhosttyResources-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func resources(_ relativePath: String, shell: String = "zsh") throws -> URL {
            let directory = root.appendingPathComponent(relativePath, isDirectory: true)
            let entrypoint = shell == "zsh" ? "zsh/.zshenv" : "bash/ghostty.bash"
            let script = directory.appendingPathComponent("shell-integration/" + entrypoint)
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# fixture shell integration\n".utf8).write(to: script)
            return directory
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("""
    @spec CONFIG-2.2: If `GHOSTTY_RESOURCES_DIR` names an existing directory containing a `shell-integration` directory, then the application shall preserve that explicit override; otherwise it shall use the bundled resources or report them unavailable.
    """, arguments: [false, true], ["zsh", "bash"])
    func validEnvOverrideWins(hasBundle: Bool, shell: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let custom = try fixture.resources("custom ghostty", shell: shell)
        let bundled = hasBundle ? try fixture.resources("bundled/ghostty") : nil
        // Keep the supplied spelling as well as the selected directory.
        let override = custom.path + "/"
        #expect(GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": override], bundledDir: bundled
        ) == .environmentOverride(override))
    }

    @Test("""
    @spec CONFIG-2.3: Otherwise, the application shall set `GHOSTTY_RESOURCES_DIR` to the `ghostty` directory vendored in GrafttyKit's resource bundle (per CONFIG-2.5), so shell integration does not depend on a separately installed Ghostty.app.
    """)
    func unsetEnvUsesBundledCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundled = try fixture.resources("bundled/ghostty")
        #expect(GhosttyRuntimeResources.resolve(processEnv: [:], bundledDir: bundled) == .bundled(bundled.path))
    }

    @Test func emptyEnvValueUsesBundledCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundled = try fixture.resources("bundled/ghostty")
        #expect(GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": ""], bundledDir: bundled
        ) == .bundled(bundled.path))
    }

    @Test(arguments: ["missing", "file", "empty", "shell-integration-file"], [false, true])
    func invalidEnvOverrideFallsBack(kind: String, hasBundle: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalid = fixture.root.appendingPathComponent("invalid")
        switch kind {
        case "file": try Data("not a directory".utf8).write(to: invalid)
        case "empty": try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        case "shell-integration-file":
            try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
            try Data("not a directory".utf8).write(to: invalid.appendingPathComponent("shell-integration"))
        default: break
        }
        let bundled = hasBundle ? try fixture.resources("bundled/ghostty") : nil
        let expected: GhosttyRuntimeResources.Resolution = bundled.map { .bundled($0.path) } ?? .unavailable
        #expect(GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": invalid.path], bundledDir: bundled
        ) == expected)
    }

    @Test func staleFlatOverrideUsesInstalledNestedBundleResources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let relativeBundle = "Graftty.app/Contents/Resources/Graftty_GrafttyKit.bundle"
        let bundled = try fixture.resources(relativeBundle + "/Contents/Resources/ghostty")
        let bundleRoot = fixture.root.appendingPathComponent(relativeBundle)
        let info = ["CFBundleIdentifier": "test.ghostty." + UUID().uuidString, "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleRoot.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: bundleRoot))
        let resolvedBundle = try #require(GhosttyRuntimeResources.bundledResourcesDir(bundle: bundle))
        #expect(resolvedBundle.standardizedFileURL == bundled.standardizedFileURL)
        let stale = bundleRoot.appendingPathComponent("ghostty").path
        #expect(!FileManager.default.fileExists(atPath: stale))
        #expect(GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": stale], bundledDir: resolvedBundle
        ) == .bundled(resolvedBundle.path))
    }

    @Test("""
    @spec CONFIG-2.4: If the vendored ghostty resources are missing from the application bundle, the application shall log a warning identifying the problem and continue with shell-integration features (OSC 7 auto-reporting, OSC 133 prompt marks, `COMMAND_FINISHED`, and `PROGRESS_REPORT`) unavailable; spawned shells shall still function.
    """, arguments: [[:], ["GHOSTTY_RESOURCES_DIR": ""]])
    func missingPayloadResolvesUnavailable(environment: [String: String]) {
        #expect(GhosttyRuntimeResources.resolve(processEnv: environment, bundledDir: nil) == .unavailable)
    }
}
