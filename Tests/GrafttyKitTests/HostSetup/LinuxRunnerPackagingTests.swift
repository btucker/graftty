import Foundation
import Testing

struct LinuxRunnerPackagingTests {
    @Test("@spec DIST-4.11: When packaging graftty-runner from a Linux archive, the build script shall select the archive architecture and send only the archive and image recipe to Docker, excluding checkout files and credentials.")
    func isolatedBuildContext() throws {
        try run("python3", "scripts/linux/runner/test-runner.py", "RunnerBuildTests")
    }

    @Test("@spec DIST-4.13: When publishing graftty-runner, release automation shall preserve the full release version by mapping build metadata's plus sign to an underscore and shall assign latest only to stable releases.")
    func releaseTagsPreserveBuildMetadata() throws {
        try run("python3", "scripts/linux/runner/test-runner.py", "RunnerTagTests")
    }

    @Test("@spec DIST-4.12: When graftty-runner starts with a persistent home volume, the image shall serve as a non-root user without systemd, support terminal input and output, and retain its identity and repositories after container replacement.",
          .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_RUNNER_IMAGE"] != nil, "Requires a built runner image and Docker"))
    func containerLifecycle() throws {
        let image = try #require(ProcessInfo.processInfo.environment["GRAFTTY_RUNNER_IMAGE"])
        try run("bash", "scripts/linux/runner/smoke-test.sh", image)
    }

    private func run(_ executable: String, _ script: String, _ arguments: String...) throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, repository.appendingPathComponent(script).path] + arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
