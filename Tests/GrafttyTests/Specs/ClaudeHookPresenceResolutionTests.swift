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
    @spec AGENT-6.49: If Graftty is unreachable, busy, or reports an error for a SessionStart hook run inside a Graftty terminal, the CLI shall still emit the Graftty skill guidance; outside a Graftty terminal, and for every other event, it shall emit an empty hook result.
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
            for event in TeamHookEvent.allCases where event != .sessionStart {
                #expect(TeamHook.unrenderedHookOutput(runtime: runtime, event: event, environment: grafttyPane) == "{}")
            }
        }
    }
}
