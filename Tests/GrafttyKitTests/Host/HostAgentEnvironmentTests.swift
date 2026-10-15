import Foundation
import Testing
@testable import GrafttyKit

struct HostAgentEnvironmentTests {
    @Test("@spec REMOTE-21.21: When a Linux host launches panes or provider plugin commands, the application shall retain the configured login shell's provider paths and make user-local native installs available without replacing earlier PATH entries.")
    func preservesUserPathsAndFindsProfileProvider() async throws {
        #expect(HostAgentEnvironment.path(inheritedPath: "/usr/bin:/bin", home: "/home/example") == "/usr/bin:/bin:/home/example/.local/bin")
        #expect(HostAgentEnvironment.path(inheritedPath: "/custom:/home/example/.local/bin:/usr/bin", home: "/home/example") == "/custom:/home/example/.local/bin:/usr/bin")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profileBin = root.appendingPathComponent("profile tools")
        try FileManager.default.createDirectory(at: profileBin, withIntermediateDirectories: true)
        let tool = profileBin.appendingPathComponent("graftty-test-provider")
        try Data("#!/bin/sh\nprintf '%s' \"$1\"\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let fakeShell = root.appendingPathComponent("configured-shell")
        try Data(("#!/bin/sh\n[ \"$1\" = -ilc ] || exit 1\nexport PATH=" + LinuxHostScripts.quote(profileBin.path + ":/usr/bin:/bin") + "\necho profile-output\nexec /bin/sh -c \"$2\"\n").utf8).write(to: fakeShell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeShell.path)
        let loginPath = try await HostAgentEnvironment.loginPath(shellPath: fakeShell.path, home: root.path)
        #expect(loginPath == profileBin.path + ":/usr/bin:/bin")
        let path = HostAgentEnvironment.path(inheritedPath: "/usr/bin:/bin", home: root.path,
            loginPath: loginPath)
        let executor = HostAgentEnvironment.executor(path: path, base: CLIRunner())
        let result = try await executor.run(command: "graftty-test-provider", args: ["profile provider found"], at: root.path)
        #expect(result.stdout == "profile provider found")
        let failure = try await executor.capture(command: "/bin/sh", args: ["-c", "exit 7"], at: root.path)
        #expect(failure.exitCode == 7)
    }

    @Test("A failed or slow configured shell falls back to the host PATH", arguments: ["exit 3", "exec /bin/sleep 30"])
    func probeFailureFallsBack(script: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = root.appendingPathComponent("shell")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let start = ContinuousClock.now
        let loginPath = try await HostAgentEnvironment.loginPath(shellPath: shell.path, home: root.path, timeout: 0.1)
        #expect(loginPath == nil)
        #expect(start.duration(to: .now) < .seconds(8))
        #expect(HostAgentEnvironment.path(inheritedPath: "/usr/bin:/bin", home: root.path, loginPath: loginPath)
            == "/usr/bin:/bin:" + root.appendingPathComponent(".local/bin").path)
    }

}
