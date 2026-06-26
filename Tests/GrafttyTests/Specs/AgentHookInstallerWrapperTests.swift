import Testing
import Foundation
import Darwin
@testable import GrafttyKit

@Suite("AgentHookInstaller — wrapper script shapes")
struct AgentHookInstallerWrapperTests {
    @Test("@spec TEAM-IDLE-1.2: When the Claude wrapper runs with `GRAFTTY_DISABLE_AGENT_HOOKS != 1`, the application shall exec `claude --settings '<inline JSON>'` so graftty's hooks layer additively over the user's settings.")
    func claudeWrapperUsesInlineSettings() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        // Inline JSON includes the three SessionStart/PostToolUse/Stop hook entries.
        #expect(script.contains("--settings"))
        #expect(script.contains("\"SessionStart\""))
        #expect(script.contains("\"PostToolUse\""))
        #expect(script.contains("\"Stop\""))
        #expect(script.contains("graftty team hook claude session-start"))

        // Trap-based unregister.
        #expect(script.contains("trap"))
        #expect(script.contains("graftty team unregister --runtime claude"))

        // No on-disk settings file path is referenced.
        #expect(!script.contains("claude-settings.json"))
    }

    @Test("Claude wrapper falls through to plain claude when GRAFTTY_DISABLE_AGENT_HOOKS=1.")
    func claudeWrapperRespectsDisable() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        #expect(script.contains("GRAFTTY_DISABLE_AGENT_HOOKS"))
        // Both branches spawn a subshell that execs the real binary.
        let execCount = script.components(separatedBy: "exec ").count - 1
        #expect(execCount >= 2)
    }

    @Test("@spec TEAM-IDLE-1.3: Claude wrapper Stop hook spawns the asyncRewake watcher.")
    func claudeWrapperStopIncludesWatcher() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        #expect(script.contains("graftty team hook claude stop"))
        #expect(script.contains("graftty team watch-inbox claude"))
        #expect(script.contains("\"asyncRewake\":true"))
    }

    @Test("Codex wrapper sets CODEX_HOME and runs sync-codex-home before exec.")
    func codexWrapperSetsCodexHome() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        #expect(script.contains("internal sync-codex-home"))
        #expect(script.contains("CODEX_HOME="))
        #expect(script.contains("/Users/x/agent-hooks/codex-home"))
        #expect(script.contains("trap"))
        #expect(script.contains("graftty team unregister --runtime codex"))
    }

    @Test(
        "@spec TEAM-PRESENCE-1.3: When the graftty wrapper launches an agent runtime, the wrapper shall register the spawned long-running runtime PID, not the short-lived registration helper PID.",
        arguments: [TeamHookRuntime.claude, .codex]
    )
    func wrapperRegistersSpawnedRuntimePID(runtime: TeamHookRuntime) {
        let script = AgentHookInstaller.wrapperScript(
            runtime: runtime,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: runtime.rawValue,
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        #expect(script.contains("agent_pid=$!"))
        #expect(script.contains(
            #"/usr/local/bin/graftty team register --runtime \#(runtime.rawValue) --pid "$agent_pid" >/dev/null 2>&1 || true"#
        ))
        #expect(script.contains(#"wait "$agent_pid""#))
        #expect(script.contains("trap cleanup EXIT"))
        #expect(script.contains("graftty team unregister --runtime \(runtime.rawValue)"))

        let agentPIDIdx = script.range(of: "agent_pid=$!")!.lowerBound
        let registerIdx = script.range(of: "team register --runtime")!.lowerBound
        let waitIdx = script.range(
            of: #"wait "$agent_pid""#,
            range: registerIdx..<script.endIndex
        )!.lowerBound
        #expect(agentPIDIdx < registerIdx)
        #expect(registerIdx < waitIdx)
    }

    @Test("Wrapper forwards termination signals to the spawned runtime child.")
    func wrapperForwardsSignalsToRuntimeChild() {
        let script = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        #expect(script.contains(#"agent_pid="""#))
        #expect(script.contains("forward_signal()"))
        #expect(script.contains(#"kill -"$sig" "$agent_pid" 2>/dev/null || true"#))
        #expect(script.contains(#"wait "$agent_pid" 2>/dev/null || true"#))
        #expect(script.contains("trap 'forward_signal TERM 143' TERM"))
        #expect(script.contains("trap 'forward_signal INT 130' INT"))
        #expect(script.contains("trap 'forward_signal HUP 129' HUP"))
        #expect(script.contains("trap cleanup EXIT"))
    }

    @Test("Wrapper runtime child resets forwarded signal dispositions before exec.")
    func wrapperResetsSignalsInRuntimeChildBeforeExec() {
        let claude = AgentHookInstaller.wrapperScript(
            runtime: .claude,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "claude",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        let codex = AgentHookInstaller.wrapperScript(
            runtime: .codex,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: "codex",
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )

        #expect(claude.contains(#"( trap - INT TERM HUP; exec "$real_binary" --settings"#))
        #expect(claude.contains(#"( trap - INT TERM HUP; exec "$real_binary" "$@" ) &"#))
        #expect(codex.contains(#"( trap - INT TERM HUP; exec env CODEX_HOME="#))
        #expect(codex.contains(#"( trap - INT TERM HUP; exec "$real_binary" "$@" ) &"#))
    }

    @Test("Generated wrapper SIGINT exits promptly and does not leave the runtime child alive.")
    func wrapperSIGINTTerminatesRuntimeChild() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapperDirectory = root.appendingPathComponent("wrapper-bin", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)

        let childPIDFile = root.appendingPathComponent("child.pid")
        let fakeGraftty = root.appendingPathComponent("graftty")
        try writeExecutable(
            """
            #!/bin/sh
            if [ "$1" = "team" ] && [ "$2" = "register" ]; then
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--pid" ]; then
                  shift
                  printf '%s\\n' "$1" > "$GRAFTTY_TEST_PID_FILE"
                  exit 0
                fi
                shift
              done
            fi
            exit 0
            """,
            to: fakeGraftty
        )

        let realCodex = realDirectory.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(
            at: realCodex,
            withDestinationURL: URL(fileURLWithPath: "/bin/sleep")
        )

        let wrapper = wrapperDirectory.appendingPathComponent("codex")
        try writeExecutable(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: wrapperDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: fakeGraftty.path,
                codexHomeDirectory: root.appendingPathComponent("codex-home", isDirectory: true).path
            ),
            to: wrapper
        )

        let process = Process()
        process.executableURL = wrapper
        process.arguments = ["30"]
        process.environment = [
            "PATH": "\(wrapperDirectory.path):\(realDirectory.path):/bin:/usr/bin",
            "GRAFTTY_TEST_PID_FILE": childPIDFile.path,
        ]
        try process.run()
        var childPID: Int32?
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            if let childPID, TeamPresenceMonitor.kernelIsAlive(childPID) {
                Darwin.kill(childPID, SIGKILL)
            }
        }

        let childPIDString = try #require(waitForFileContents(childPIDFile, timeout: 2.0))
        childPID = (childPIDString.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).intValue
        #expect((childPID ?? 0) > 0)

        Darwin.kill(process.processIdentifier, SIGINT)

        #expect(waitUntil(timeout: 2.0) { !process.isRunning })
        if !process.isRunning {
            process.waitUntilExit()
            #expect(process.terminationStatus == 130)
        }
        let pid = try #require(childPID)
        #expect(waitUntil(timeout: 1.0) { !TeamPresenceMonitor.kernelIsAlive(pid) })
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-wrapper-signal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
    }

    private func waitForFileContents(_ url: URL, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = try? String(contentsOf: url, encoding: .utf8), !value.isEmpty {
                return value
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate()
    }
}
