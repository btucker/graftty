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
