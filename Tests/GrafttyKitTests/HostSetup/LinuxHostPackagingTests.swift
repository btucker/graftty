import Foundation
import Testing

struct LinuxHostPackagingTests {
    @Test("@spec DIST-4.8: When a Linux zmx build restores compiled artifacts, the release scripts shall execute the unit tests again, retain format validation and ReleaseSafe compilation, and isolate cache entries by architecture and build inputs.")
    func warmCompilationCacheStillRunsTests() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "ZmxBuildTests.test_warm_cache_preserves_test_execution"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("@spec DIST-4.7: If Linux zmx builds encounter a transient dependency download failure, then the release scripts shall retry at most three times, preserve exhausted failures, and stop immediately for compiler or test failures.")
    func transientDependencyDownloadsAreRetried() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "ZmxBuildTests"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("@spec DIST-4.10: When building Linux zmx, the release scripts shall run its complete test suite in the same ReleaseSafe mode as the shipped executable, retaining runtime safety checks for large-history tests.")
    func terminalTestsMatchShippedSafetyMode() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "ZmxBuildTests.test_tests_use_the_shipped_safety_mode"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

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
        // ZmxBuildTests and PackagingBuildTests run under their own specs.
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "InstallerTests", "LibraryTests"]
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

    @Test("@spec DIST-4.5: When a local Linux archive uses the shared SwiftPM build directory, the packaging script shall hold its lock until both executables and their resources have been copied into the archive staging directory.")
    func sharedBuildArtifactsRemainLockedUntilCopied() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "PackagingBuildTests"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("@spec DIST-4.6: When Linux installers run concurrently for the same user, the installer shall serialize release and service changes through completion or rollback so a failed install cannot remove a successful replacement.")
    func concurrentInstallersDoNotUndoSuccessfulUpgrades() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "InstallerTests.test_concurrent_upgrade_cannot_roll_back_another_install"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("@spec DIST-4.3: When CI or a release builds Linux artifacts, the workflows shall build and verify x86_64 and aarch64 archives on Ubuntu 24.04 before release upload.")
    func architectureWorkflowAndReleaseHandoff() throws {
        let workflow = try repositoryText(".github/workflows/linux.yml")
        let release = try repositoryText(".github/workflows/release.yml")
        #expect(workflow.contains("runner: ubuntu-24.04\n"))
        #expect(workflow.contains("runner: ubuntu-24.04-arm\n"))
        #expect(workflow.contains("scripts/linux/smoke-test.sh"))
        #expect(release.contains("needs: [release, linux-build]"))
        #expect(release.contains("linux-artifacts/*.tar.gz.sha256"))
    }

    @Test("@spec DIST-4.9: When the Linux smoke test installs Git inside the fresh container, the script shall run every apt-get command under a kill-backed timeout with apt retries and a per-connection timeout shorter than that bound, and shall print the apt output with the exit status on failure, so a mirror stall fails fast with a diagnostic instead of consuming the job timeout in silence.")
    func smokeTestBoundsAptStep() throws {
        let script = try repositoryText("scripts/linux/smoke-test.sh")
        let lines = script
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
        let aptCommands = lines.filter { $0.contains("apt-get ") }
        #expect(!aptCommands.isEmpty)
        for command in aptCommands {
            #expect(command.hasPrefix("apt_bounded apt-get "), "unbounded apt command: \(command)")
        }

        // Numeric relationships: a positive outer bound and a per-connection timeout below it.
        let outerText = try #require(try firstMatch(#"^apt_timeout=(\d+)$"#, in: script))
        let outer = try #require(Int(outerText))
        let perConnectionText = try #require(try firstMatch(#"Acquire::http::Timeout=(\d+)"#, in: script))
        let perConnection = try #require(Int(perConnectionText))
        #expect(outer > 0)
        #expect(perConnection > 0 && perConnection < outer)
        #expect(script.contains("Acquire::Retries="))

        // Execute the extracted helper with a recording `timeout` stub: a failing command must
        // stop the script with its own status, dump its log, and a passing one must continue.
        let scriptLines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let helperStart = try #require(scriptLines.firstIndex { $0.hasPrefix("apt_timeout=") })
        let helperEnd = try #require(scriptLines[helperStart...].firstIndex { $0 == "}" })
        let helper = scriptLines[helperStart...helperEnd].joined(separator: "\n") + "\n"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-apt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let logPath = scratch.appendingPathComponent("apt.log").path
        let argsPath = scratch.appendingPathComponent("timeout-args").path
        let program = """
        set -euo pipefail
        apt_log='\(logPath)'
        timeout() { printf '%s\\n' "$@" > '\(argsPath)'; shift 3; "$@"; }
        \(helper)
        apt_bounded sh -c 'echo boom; exit 100' || { echo "status=$?"; cp "$apt_log" "$apt_log.failed"; }
        apt_bounded true && echo continued
        """
        let run = try runBash(program)
        #expect(run.stdout.contains("status=100"), "failed apt step must propagate its status: \(run.stdout)")
        #expect(run.stdout.contains("continued"), "passing apt step must let the script continue: \(run.stdout)")
        #expect(run.stderr.contains("exit 100"), "diagnostic must name the exit status: \(run.stderr)")
        #expect(run.stderr.contains("boom"), "diagnostic must dump the apt log: \(run.stderr)")
        let log = try String(contentsOfFile: logPath + ".failed", encoding: .utf8)
        #expect(log.contains("boom"), "apt output must be captured in the log file")
        let timeoutArgs = try String(contentsOfFile: argsPath, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(timeoutArgs.count >= 4)
        #expect(timeoutArgs.first == "-k")
        #expect((Int(timeoutArgs.dropFirst().first ?? "") ?? 0) > 0, "kill grace must be positive")
        #expect(Int(timeoutArgs.dropFirst(2).first ?? "") == outer, "outer bound must be apt_timeout")
    }

    private func firstMatch(_ pattern: String, in text: String, group: Int = 1) throws -> String? {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .dotMatchesLineSeparators])
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let groupRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[groupRange])
    }

    private func runBash(_ program: String) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", program]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (stdout, stderr, process.terminationStatus)
    }

    private func repositoryText(_ relativePath: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
