import Testing
import Foundation
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
        // Both branches must end in an exec of the real binary.
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
        "@spec TEAM-PRESENCE-1.3: When the graftty wrapper launches an agent runtime, the wrapper shall asynchronously invoke `graftty team register --runtime <runtime>` (backgrounded, output redirected) before exec'ing the real binary, so the model is not required to type the registration command itself.",
        arguments: [TeamHookRuntime.claude, .codex]
    )
    func wrapperRegistersAsynchronouslyBeforeExec(runtime: TeamHookRuntime) {
        let script = AgentHookInstaller.wrapperScript(
            runtime: runtime,
            wrapperDirectory: "/Users/x/agent-hooks/bin",
            realCommandName: runtime.rawValue,
            grafttyCLIPath: "/usr/local/bin/graftty",
            codexHomeDirectory: "/Users/x/agent-hooks/codex-home"
        )
        // Async register, fully detached and silent.
        #expect(script.contains(
            "/usr/local/bin/graftty team register --runtime \(runtime.rawValue) >/dev/null 2>&1 &"
        ))
        // Register fires before exec of the real binary so it races with
        // the agent's startup rather than serializing.
        let registerIdx = script.range(of: "team register --runtime")!.lowerBound
        let execIdx = script.range(of: #"exec "$real_binary""#)!.lowerBound
        #expect(registerIdx < execIdx)
    }
}
