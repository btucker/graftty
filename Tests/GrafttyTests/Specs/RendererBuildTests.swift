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

    @Test("@spec DIST-1.10: When Xcode Cloud clones the repository for GrafttyMobile, its post-clone script shall prepare libghostty for iOS before Xcode resolves the package.")
    func xcodeCloudPreparesNativeDependencies() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let clone = FileManager.default.temporaryDirectory.appendingPathComponent("xcode-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let log = clone.appendingPathComponent("calls.log")
        let deps = clone.appendingPathComponent("scripts/deps")
        try "#!/bin/sh\necho \"$*\" >> \"\(log.path)\"\n".write(to: deps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: deps.path)

        let process = Process()
        process.executableURL = root.appendingPathComponent("Apps/GrafttyMobile/ci_scripts/ci_post_clone.sh")
        process.environment = ["CI_PRIMARY_REPOSITORY_PATH": clone.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: log, encoding: .utf8) == "prepare ghostty --platforms ios\n")
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
