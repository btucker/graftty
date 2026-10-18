import Foundation
import Testing

@Suite("Renderer build compatibility")
struct RendererBuildTests {
    @Test("@spec DIST-1.6: When a development build has no explicit renderer override, the build shall use the committed published dependency and diagnose ignored local packages; an explicitly selected stale renderer or a release requiring paging shall fail before compilation.")
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
