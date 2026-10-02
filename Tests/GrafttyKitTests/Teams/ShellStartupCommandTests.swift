import Foundation
import Testing
@testable import GrafttyKit

@Suite
struct ShellStartupCommandTests {
    @Test("A real daemon starts the command once and reattachment does not repeat it",
          .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TEST_ZMX"] != nil))
    func realDaemonStartsOnce() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GRAFTTY_TEST_ZMX"])
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("hooks")
        _ = try AgentHookInstaller(rootDirectory: hooks, grafttyCLIPath: "/usr/bin/false").install()
        let marker = root.appendingPathComponent("started")
        let receipt = root.appendingPathComponent("accepted")
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: executable), zmxDir: root)
        let spawn = ZmxSpawnConfiguration.make(
            launcher: launcher, paneSessionID: PaneSessionID(), worktreePath: root.path,
            socketPath: "/tmp/unused.sock", processEnv: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin", "HOME": root.path],
            bundleURL: root, ghosttyResourcesDir: nil, agentHooksDisabled: true, agentHooksRoot: hooks,
            initialCommand: "printf started >> " + WorktreeAgentLaunchCommand.shellLiteral(marker.path),
            startupReceipt: receipt
        )
        defer { launcher.kill(sessionName: spawn.sessionName) }
        let config = ZmxAttachEngine.Config(zmxExecutable: launcher.executable, zmxDir: root,
            sessionName: spawn.sessionName, workingDirectory: root, spawnConfiguration: spawn)
        let first = ZmxAttachEngine(config: config)
        first.onPTYData = { _ in }
        try first.start()
        defer { first.close() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "started")
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        await first.close()
        let second = ZmxAttachEngine(config: config)
        second.onPTYData = { _ in }
        try second.start()
        defer { second.close() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "started")
    }

    @Test("Host attachment runs the command after delayed login initialization without renderer input")
    func attachmentCarriesStartupCommand() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("hooks")
        _ = try AgentHookInstaller(rootDirectory: hooks, grafttyCLIPath: "/usr/bin/false").install()
        try "trap 'exit' TERM\n/bin/sleep 0.15\nexport GRAFTTY_LOGIN_COMPLETE=yes\n"
            .write(to: root.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
        let zmx = root.appendingPathComponent("zmx")
        try "#!/bin/sh\nexec \"$SHELL\" -il\n"
            .write(to: zmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)
        let marker = root.appendingPathComponent("started")
        let launcher = ZmxLauncher(executable: zmx, zmxDir: root)
        let spawn = ZmxSpawnConfiguration.make(
            launcher: launcher, paneSessionID: PaneSessionID(), worktreePath: root.path,
            socketPath: "/tmp/unused.sock", processEnv: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin", "HOME": root.path],
            bundleURL: root, ghosttyResourcesDir: nil, agentHooksDisabled: true, agentHooksRoot: hooks,
            initialCommand: "printf '%s' \"$GRAFTTY_LOGIN_COMPLETE\" > " + WorktreeAgentLaunchCommand.shellLiteral(marker.path)
        )
        let engine = ZmxAttachEngine(config: .init(zmxExecutable: zmx, zmxDir: root,
            sessionName: spawn.sessionName, workingDirectory: root, spawnConfiguration: spawn))
        engine.onPTYData = { _ in }
        try engine.start()
        defer { engine.close() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "yes")
    }

    @Test("@spec AGENT-5.22: When a fresh zsh or bash session has an initial command, the application shall run it once after shell initialization and first-prompt environment hooks without waiting for a terminal renderer's PWD callback, preserve a user's custom ZDOTDIR, and remove the startup command from the environment before user initialization can spawn another shell.", arguments: [false, true])
    func startsAfterInitializationWithoutRenderer(customZDOTDIR: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let hooks = root.appendingPathComponent("hooks")
        _ = try AgentHookInstaller(rootDirectory: hooks, grafttyCLIPath: "/usr/bin/false").install()
        let custom = home.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let zmx = root.appendingPathComponent("zmx")
        try "#!/bin/sh\nif [ -n \"$3\" ]; then exec \"$3\" -i; else exec \"$SHELL\" -il; fi\n"
            .write(to: zmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)
        for shell in ["zsh", "bash"] {
            let marker = root.appendingPathComponent(shell + ".result")
            // A nested shell during user init must not inherit the command.
            let redirect = shell == "zsh" && customZDOTDIR ? "export ZDOTDIR=" + WorktreeAgentLaunchCommand.shellLiteral(custom.path) + "\n" : ""
            try ("trap 'exit' TERM\n[ -z \"${GRAFTTY_INITIAL_COMMAND-}\" ] || exit 91\nexport GRAFTTY_INIT_COMPLETE=yes\n" + redirect)
                .write(to: home.appendingPathComponent(shell == "zsh" ? ".zshenv" : ".bashrc"), atomically: true, encoding: .utf8)
            if shell == "zsh" {
                try "_project_env() { export GRAFTTY_PROMPT_COMPLETE=yes; }\nprecmd_functions+=(_project_env)\n"
                    .write(to: (customZDOTDIR ? custom : home).appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            } else {
                try "trap 'exit' TERM\n[ -z \"${GRAFTTY_INITIAL_COMMAND-}\" ] || exit 91\nexport GRAFTTY_INIT_COMPLETE=yes\nPROMPT_COMMAND='export GRAFTTY_PROMPT_COMPLETE=yes; # user hook'\n"
                    .write(to: home.appendingPathComponent(".bashrc"), atomically: true, encoding: .utf8)
            }
            let config = ZmxSpawnConfiguration.make(
                launcher: ZmxLauncher(executable: zmx, zmxDir: root),
                paneSessionID: PaneSessionID(), worktreePath: root.path, socketPath: "/tmp/unused.sock",
                processEnv: ["SHELL": "/bin/" + shell, "PATH": "/usr/bin:/bin", "HOME": home.path,
                             "__GRAFTTY_BASH_PROFILE_SOURCED": "1"],
                bundleURL: root, ghosttyResourcesDir: nil, agentHooksDisabled: true, agentHooksRoot: hooks,
                initialCommand: "test \"$GRAFTTY_INIT_COMPLETE/$GRAFTTY_PROMPT_COMPLETE\" = yes/yes && printf '%s\\n' \"a 'quoted' task\" >> " + WorktreeAgentLaunchCommand.shellLiteral(marker.path) + "; /bin/" + shell + " -ic true"
            )
            let engine = ZmxAttachEngine(config: .init(zmxExecutable: zmx, zmxDir: root,
                sessionName: config.sessionName, workingDirectory: root, spawnConfiguration: config))
            engine.onPTYData = { _ in }
            try engine.start()
            defer { engine.close() }
            let deadline = ContinuousClock.now + .seconds(3)
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try String(contentsOf: marker, encoding: .utf8) == "a 'quoted' task\n")
            #expect(config.env["GRAFTTY_AGENT_HOOKS_BIN"] == nil)
        }
    }
}
