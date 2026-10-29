import Foundation
import Testing

@Suite("Renderer build compatibility")
struct RendererBuildTests {
    @Test("@spec DIST-1.6: When Graftty selects its terminal dependency, development, CI, and release builds shall enable paging from the same published revision, diagnose ignored local packages, and reject explicit overrides whose package-owned build provenance does not match their sources and binaries.")
    func rendererSelection() throws {
        try runFixtures()
    }

    @Test("@spec DIST-1.7: When the shared wrapper, bundle script, or CI builds with a changed renderer or headers, the build shall apply a distinct Clang module signature to application and dependency targets.")
    func rendererModuleIdentity() throws {
        try runFixtures("RendererSelectionTests.test_valid_package_enables_paging_and_distinct_module_signature")
    }

    private func runFixtures(_ test: String? = nil) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", root.appendingPathComponent("scripts/ghostty-paging/test-package-selection.py").path] + (test.map { [$0] } ?? [])
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
