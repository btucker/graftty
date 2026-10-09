import Foundation
import Testing

struct LinuxHostPackagingTests {
    private var repository: URL {
        var path = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { path.deleteLastPathComponent() }
        return path
    }

    @Test("@spec DIST-4.1: When a Linux host archive is built, the release scripts shall include the host, CLI, pinned zmx, resources, shared runtime libraries, and a root installer for its architecture.",
          .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_LINUX_ARCHIVE"] != nil, "Requires a built Linux archive"))
    func archiveContainsPortableRuntime() throws {
        let archive = try #require(ProcessInfo.processInfo.environment["GRAFTTY_LINUX_ARCHIVE"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tar", "-tzf", archive]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let entries = String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(entries.contains("./install.sh"))
        for suffix in ["/install.sh", "/bin/graftty", "/bin/graftty-host", "/bin/zmx", "/libexec/graftty-host", "/libexec/graftty-cli", "/libexec/graftty", "/lib/libswiftCore.so", "/share/terminfo/78/xterm-ghostty"] {
            #expect(entries.contains { $0.hasSuffix(suffix) }, "Archive missing \(suffix)")
        }
    }

    @Test("@spec DIST-4.2: When a Linux archive is installed, the installer shall use the invoking user's directories and systemd service with explicit ports and KillMode=process so zmx sessions survive host restarts.")
    func installerBehavior() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("@spec DIST-4.4: If an installed Linux host does not become ready on the requested SSH port, then the installer shall stop the replacement and restore the previously running host before reporting failure.")
    func failedStartupRestoresPriorService() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "InstallerTests.test_failed_readiness_stops_replacement_before_restoring_service"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("@spec DIST-4.3: When CI or a release builds Linux artifacts, the workflows shall build and verify x86_64 and aarch64 archives on Ubuntu 24.04 before release upload.")
    func architectureWorkflowAndReleaseHandoff() throws {
        let workflow = try String(contentsOf: repository.appendingPathComponent(".github/workflows/linux.yml"), encoding: .utf8)
        let release = try String(contentsOf: repository.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        #expect(workflow.contains("runner: ubuntu-24.04\n"))
        #expect(workflow.contains("runner: ubuntu-24.04-arm\n"))
        #expect(workflow.contains("scripts/linux/smoke-test.sh"))
        #expect(release.contains("needs: [release, linux-build]"))
        #expect(release.contains("linux-artifacts/*.tar.gz.sha256"))
    }
}
