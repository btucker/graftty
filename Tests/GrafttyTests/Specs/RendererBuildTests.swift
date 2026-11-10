import Foundation
import Testing

@Suite("Renderer build compatibility")
struct RendererBuildTests {
    @Test("@spec DIST-1.6: When Graftty builds its terminal dependency, development, CI, and release builds shall build libghostty from the pinned Ghostty commit and the patch series in deps/ghostty, reuse a cached build only when every input matches its key, and report the first patch that no longer applies.")
    func rendererSelection() throws {
        try run(["scripts/test-deps.sh"])
    }

    @Test("@spec DIST-1.7: When the shared wrapper, bundle script, or CI builds with a changed renderer or headers, the build shall apply a distinct Clang module signature to application and dependency targets.")
    func rendererModuleIdentity() throws {
        try run(["python3", "-B", "scripts/ghostty-paging/test-renderer-identity.py"])
    }

    private func run(_ arguments: [String]) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
