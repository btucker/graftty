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
    private let bundled = URL(fileURLWithPath: "/bundle/ghostty", isDirectory: true)

    @Test("""
    @spec CONFIG-2.2: If `GHOSTTY_RESOURCES_DIR` is already set and non-empty in the process environment, the application shall not override it; the user's explicit setting wins.
    """)
    func envOverrideWins() {
        let r = GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": "/custom/ghostty"],
            bundledDir: bundled
        )
        #expect(r == .environmentOverride("/custom/ghostty"))
    }

    @Test("""
    @spec CONFIG-2.3: Otherwise, the application shall set `GHOSTTY_RESOURCES_DIR` to the `ghostty` directory vendored in GrafttyKit's resource bundle (per CONFIG-2.5), so shell integration does not depend on a separately installed Ghostty.app.
    """)
    func unsetEnvUsesBundledCopy() {
        let r = GhosttyRuntimeResources.resolve(processEnv: [:], bundledDir: bundled)
        #expect(r == .bundled("/bundle/ghostty"))
    }

    @Test func emptyEnvValueUsesBundledCopy() {
        let r = GhosttyRuntimeResources.resolve(
            processEnv: ["GHOSTTY_RESOURCES_DIR": ""],
            bundledDir: bundled
        )
        #expect(r == .bundled("/bundle/ghostty"))
    }

    @Test("""
    @spec CONFIG-2.4: If the vendored ghostty resources are missing from the application bundle, the application shall log a warning identifying the problem and continue with shell-integration features (OSC 7 auto-reporting, OSC 133 prompt marks, `COMMAND_FINISHED`, and `PROGRESS_REPORT`) unavailable; spawned shells shall still function.
    """)
    func missingPayloadResolvesUnavailable() {
        let r = GhosttyRuntimeResources.resolve(processEnv: [:], bundledDir: nil)
        #expect(r == .unavailable)
    }
}
