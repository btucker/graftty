import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

@Suite("Claude hook presence resolution")
struct ClaudeHookPresenceResolutionTests {
    @Test("SessionStart retries briefly while Claude publishes its native peer registry row.")
    func sessionStartRetriesRegistryDiscovery() {
        let expected = record(sessionID: "after-clear")
        var attempts = 0
        var waits = 0

        let resolved = TeamHook.resolveClaudeNativePresence(
            event: .sessionStart,
            lookup: {
                attempts += 1
                return attempts == 3 ? expected : nil
            },
            wait: { waits += 1 }
        )

        #expect(resolved == expected)
        #expect(attempts == 3)
        #expect(waits == 2)
    }

    @Test("Routine Claude hooks do not retry a missing native registry row.")
    func routineHooksUseOneRegistryLookup() {
        var attempts = 0
        var waits = 0

        let resolved = TeamHook.resolveClaudeNativePresence(
            event: .postToolUse,
            lookup: {
                attempts += 1
                return nil
            },
            wait: { waits += 1 }
        )

        #expect(resolved == nil)
        #expect(attempts == 1)
        #expect(waits == 0)
    }

    @Test("""
    @spec AGENT-6.62: If the Claude Stop hook cannot read a native registry row for its session while the previously registered presence record still names a live process and an existing messaging socket, then the CLI shall keep that record instead of retiring the pane's identity.
    """, arguments: ["live", "dead-process", "reused-pid", "missing-socket", "no-prior"])
    func stopRetiresPresenceOnlyWhenPriorEndpointIsGone(_ scenario: String) {
        let prior = scenario == "no-prior" ? nil : record(sessionID: "current")
        let retire = TeamHook.shouldRetireClaudePresence(
            event: .stop,
            prior: prior,
            processStartTime: { pid in
                switch scenario {
                case "dead-process": nil
                case "reused-pid": 2_002
                default: pid == 101 ? 1_001 : nil
                }
            },
            isSocket: { path in scenario != "missing-socket" && path == "/tmp/claude-101.sock" }
        )
        #expect(retire == (scenario != "live"))
    }

    @Test("Routine Claude hooks never retire presence on a failed registry lookup.")
    func routineHooksKeepPresence() {
        for event in TeamHookEvent.allCases where event != .stop {
            #expect(!TeamHook.shouldRetireClaudePresence(
                event: event, prior: nil, processStartTime: { _ in nil }, isSocket: { _ in false }
            ))
        }
    }

    private func record(sessionID: String) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .claude,
            paneSessionName: "graftty-aabbccdd",
            pid: 101,
            processStartTimeMicroseconds: 1_001,
            registeredAt: Date(timeIntervalSince1970: 10),
            runtimeSessionID: sessionID,
            agentID: TeamAgentIdentity(
                runtime: .claude,
                nativeSessionID: sessionID
            ).rawValue,
            transport: .claude(socketPath: "/tmp/claude-101.sock", protocolVersion: 1)
        )
    }
}

@Suite("Team hook output when Graftty cannot render the hook")
struct TeamHookUnrenderedOutputTests {
    @Test("""
    @spec AGENT-6.49: If Graftty is unreachable, busy, or reports an error inside a Graftty terminal, then the CLI shall emit skill guidance for SessionStart and a recap reminder for UserPromptSubmit; outside a Graftty terminal and for other events it shall emit an empty hook result.
    """)
    func sessionStartFallsBackToSkillGuidance() throws {
        let grafttyPane = ["GRAFTTY_SOCK": "/tmp/graftty.sock"]
        for runtime in [TeamHookRuntime.codex, .claude] {
            #expect(
                TeamHook.unrenderedHookOutput(runtime: runtime, event: .sessionStart, environment: grafttyPane)
                    == (try TeamHookRenderer.sessionStart(runtime: runtime))
            )
            #expect(TeamHook.unrenderedHookOutput(runtime: runtime, event: .sessionStart, environment: [:]) == "{}")
            #expect(TeamHook.unrenderedHookOutput(
                runtime: runtime, event: .sessionStart, environment: ["GRAFTTY_SOCK": ""]
            ) == "{}")
            #expect(TeamHook.unrenderedHookOutput(runtime: runtime, event: .userPromptSubmit, environment: grafttyPane)
                == (try TeamHookRenderer.userPromptSubmit()))
            #expect(TeamHook.unrenderedHookOutput(runtime: runtime, event: .userPromptSubmit, environment: [:]) == "{}")
            for event in TeamHookEvent.allCases where event != .sessionStart && event != .userPromptSubmit {
                #expect(TeamHook.unrenderedHookOutput(runtime: runtime, event: event, environment: grafttyPane) == "{}")
            }
        }
    }
}
