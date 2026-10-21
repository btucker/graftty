import Foundation
import Testing
@testable import GrafttyKit

@Suite("LoginShellEnvProbe output parsing")
struct ShellEnvProbeTests {
    @Test func parseValueOutputDropsGhosttyOSCWhenEditorUnset() {
        let raw = "\u{1B}]1337;RemoteHost=btucker@m4-mbp.localdomain\u{07}\u{1B}]1337;CurrentDir=/\u{07}\u{1B}]1337;ShellIntegrationVersion=14;shell=zsh\u{07}\n"

        #expect(LoginShellEnvProbe.parseValueOutput(Data(raw.utf8)) == nil)
    }

    @Test func parseValueOutputDropsVisibleGhosttyOSCLeakWhenControlBytesAreMissing() {
        let raw = "]1337;RemoteHost=btucker@m4-mbp.localdomain]1337;CurrentDir=/]1337;ShellIntegrationVersion=14;shell=zsh\n"

        #expect(LoginShellEnvProbe.parseValueOutput(Data(raw.utf8)) == nil)
    }

    @Test func parseValueOutputKeepsEditorSurroundedByGhosttyOSC() {
        let raw = "\u{1B}]1337;RemoteHost=btucker@m4-mbp.localdomain\u{07}nvim\n\u{1B}]1337;CurrentDir=/\u{07}"

        #expect(LoginShellEnvProbe.parseValueOutput(Data(raw.utf8)) == "nvim")
    }
}

/// Runs `LoginShellEnvProbe` against a fake `/bin/sh` login shell.
@Suite("LoginShellEnvProbe subprocess")
struct LoginShellEnvProbeSubprocessTests {
    /// A private directory holding the fake shell, plus any PID files the
    /// script writes there.
    private struct FakeShell {
        let directory: URL
        var path: String { directory.appendingPathComponent("shell").path }

        init(script: (URL) -> String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-shell-probe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ("#!/bin/sh\n" + script(directory)).write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }

        func pid(_ name: String) -> pid_t? {
            let url = directory.appendingPathComponent(name)
            return (try? String(contentsOf: url, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test("@spec EDITOR-1.11: When login-shell rc files write more output than a pipe buffer holds, the application shall still return the probed value within the probe timeout rather than stall on the full pipe.")
    func valueSurvivesRCFilesThatFloodStdoutAndStderr() throws {
        let shell = try FakeShell { _ in
            """
            head -c 300000 /dev/zero | tr '\\0' x
            echo
            head -c 300000 /dev/zero | tr '\\0' y >&2
            echo nvim
            """
        }
        defer { shell.remove() }

        #expect(LoginShellEnvProbe(shellPath: shell.path, timeout: 5).value(forName: "EDITOR") == "nvim")
    }

    @Test("@spec EDITOR-1.12: When a login-shell rc file leaves a background job holding the probe stdout open, the application shall return the probed value once the shell exits rather than wait for the background job.")
    func valueSurvivesBackgroundJobHoldingStdout() throws {
        let shell = try FakeShell { directory in
            """
            sleep 30 &
            echo $! > '\(directory.path)/background.pid'
            echo nvim
            """
        }
        defer { shell.remove() }

        let value = LoginShellEnvProbe(shellPath: shell.path, timeout: 5).value(forName: "EDITOR")
        if let background = shell.pid("background.pid") { kill(background, SIGKILL) }
        #expect(value == "nvim")
    }

    @Test("@spec EDITOR-1.13: If the login-shell probe exceeds its timeout, then the application shall kill the shell with SIGKILL, because an interactive shell ignores SIGTERM.")
    func timedOutShellIgnoringTerminateIsKilled() async throws {
        let shell = try FakeShell { directory in
            """
            echo $$ > '\(directory.path)/shell.pid'
            trap '' TERM
            exec sleep 30
            """
        }
        defer { shell.remove() }

        #expect(LoginShellEnvProbe(shellPath: shell.path, timeout: 2).value(forName: "EDITOR") == nil)
        let pid = try #require(shell.pid("shell.pid"))
        // The loose bound only waits out Foundation reaping the child; a
        // shell that survived the timeout would keep sleeping for 30 s.
        let deadline = ContinuousClock.now + .seconds(10)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let survived = kill(pid, 0) == 0
        if survived { kill(pid, SIGKILL) }
        #expect(!survived, "timed-out probe shell \(pid) is still running")
    }
}
