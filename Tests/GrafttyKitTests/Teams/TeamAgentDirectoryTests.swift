import Foundation
import Testing
@testable import GrafttyKit

@Suite("Native team-agent directory")
struct TeamAgentDirectoryTests {
    @Test("""
    @spec AGENT-6.2: When Graftty observes a top-level Claude or Codex session, the application shall expose a stable canonical agent ID shaped as `<runtime>-<12 lowercase hex characters>` and an address shaped as `<canonical-worktree-path>#<agent-id>`; provider and worktree display names shall not participate in routing identity.
    """)
    func canonicalIdentityIsStableAndIgnoresDisplayName() throws {
        let first = TeamAgentIdentity(runtime: .claude, nativeSessionID: "session-123")
        let second = TeamAgentIdentity(runtime: .claude, nativeSessionID: "session-123")

        #expect(first == second)
        #expect(first.rawValue.hasPrefix("claude-"))
        #expect(first.rawValue.count == "claude-".count + 12)
        #expect(first.rawValue.dropFirst("claude-".count).allSatisfy { $0.isHexDigit && !$0.isUppercase })

        let record = presence(
            runtime: .claude,
            sessionID: "session-123",
            displayName: "reviewer renamed twice",
            registeredAt: 10
        )
        let agent = try #require(TeamAgentDirectory(records: [record], isReachable: { _ in true }).agents.first)
        #expect(agent.id == first)
        #expect(agent.displayName == "reviewer renamed twice")
        #expect(agent.address(worktreeAddress: "/repo/feature") == "/repo/feature#\(first.rawValue)")
    }

    @Test("""
    @spec AGENT-6.3: While multiple top-level agents are live in one worktree, the application shall route the unsuffixed worktree address to the earliest reachable agent across runtimes, route a canonical suffixed address only to that exact agent, exclude native subagents, and reject an explicit stale or unknown address without enqueuing or falling back.
    """)
    func resolutionIsOrderedExactAndFailClosed() throws {
        let stale = presence(runtime: .codex, sessionID: "stale", registeredAt: 1)
        let subagent = presence(runtime: .codex, sessionID: "child", registeredAt: 2, isSubagent: true)
        let first = presence(runtime: .claude, sessionID: "claude", registeredAt: 3)
        let later = presence(runtime: .codex, sessionID: "codex", registeredAt: 4)
        let directory = TeamAgentDirectory(
            records: [later, subagent, first, stale],
            isReachable: { $0.runtimeSessionID != "stale" }
        )

        let resolvedDefault = try directory.resolve(
            worktreePath: "/repo/feature",
            explicitAgentID: nil
        )
        let defaultAgent = try #require(resolvedDefault)
        #expect(defaultAgent.runtime == .claude)
        #expect(defaultAgent.identitySource == "claude")
        #expect(directory.agents.count == 3)

        let laterID = TeamAgentIdentity(runtime: .codex, nativeSessionID: "codex")
        let resolvedExact = try directory.resolve(
            worktreePath: "/repo/feature",
            explicitAgentID: laterID.rawValue
        )
        let exact = try #require(resolvedExact)
        #expect(exact.id == laterID)

        #expect(throws: TeamAgentDirectoryError.explicitAgentUnavailable(laterID.rawValue)) {
            _ = try TeamAgentDirectory(
                records: [later],
                isReachable: { _ in false }
            ).resolve(worktreePath: "/repo/feature", explicitAgentID: laterID.rawValue)
        }
        #expect(throws: TeamAgentDirectoryError.explicitAgentNotFound("codex-000000000000")) {
            _ = try directory.resolve(
                worktreePath: "/repo/feature",
                explicitAgentID: "codex-000000000000"
            )
        }
    }

    @Test("Exact lookup skips a stale duplicate of a resumed native session.")
    func exactLookupUsesReachableDuplicateIdentity() throws {
        let stale = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .claude,
            paneSessionName: "graftty-stale",
            pid: 100,
            processStartTimeMicroseconds: 1_000,
            registeredAt: Date(timeIntervalSince1970: 1),
            runtimeSessionID: "resumed-session"
        )
        let resumed = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .claude,
            paneSessionName: "graftty-resumed",
            pid: 101,
            processStartTimeMicroseconds: 2_000,
            registeredAt: Date(timeIntervalSince1970: 2),
            runtimeSessionID: "resumed-session"
        )
        let identity = TeamAgentIdentity(runtime: .claude, nativeSessionID: "resumed-session")
        let directory = TeamAgentDirectory(
            records: [stale, resumed],
            isReachable: { $0.paneSessionName == "graftty-resumed" }
        )

        let selected = try directory.resolve(
            worktreePath: "/repo/feature",
            explicitAgentID: identity.rawValue
        )

        #expect(selected?.paneSessionName == "graftty-resumed")
    }

    @Test("A provider session ID never falls back to another pane-less session.")
    func sessionIdentityDoesNotCrossPaneLessAgents() {
        let first = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .claude,
            paneSessionName: nil,
            pid: 100,
            registeredAt: Date(timeIntervalSince1970: 1),
            runtimeSessionID: "first",
            agentID: "claude-000000000001"
        )
        let second = TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .claude,
            paneSessionName: nil,
            pid: 101,
            registeredAt: Date(timeIntervalSince1970: 2),
            runtimeSessionID: "second",
            agentID: "claude-000000000002"
        )

        #expect(TeamAgentSessionIdentityResolver.agentID(
            records: [first, second],
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .claude,
            sessionID: "second",
            paneSessionName: nil
        ) == second.agentID)
        #expect(TeamAgentSessionIdentityResolver.agentID(
            records: [first, second],
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: .claude,
            sessionID: "missing",
            paneSessionName: nil
        ) == nil)
    }

    @Test("A runtime-qualified default selects the earliest reachable agent of that runtime.")
    func runtimeQualifiedDefault() throws {
        let codex = presence(runtime: .codex, sessionID: "codex-first", registeredAt: 1)
        let claude = presence(runtime: .claude, sessionID: "claude-second", registeredAt: 2)
        let directory = TeamAgentDirectory(records: [codex, claude], isReachable: { _ in true })

        let selected = try directory.resolve(
            worktreePath: "/repo/feature",
            runtime: .claude,
            explicitAgentID: nil
        )

        #expect(selected?.runtime == .claude)
        #expect(selected?.identitySource == "claude-second")
    }

    @Test("""
    @spec AGENT-6.4: When `graftty team list` describes a worktree with observed agents, the application shall expose repository-to-worktree-to-agent-to-pane hierarchy in its stable JSON model, including canonical address, runtime, reachability, optional native display label, and optional pane session.
    """)
    func listModelNestsAgentsAndPanes() throws {
        let identity = TeamAgentIdentity(runtime: .claude, nativeSessionID: "session-123")
        let agent = TeamListAgent(
            id: identity.rawValue,
            address: "/repo/feature#\(identity.rawValue)",
            runtime: .claude,
            displayName: "worker",
            isReachable: true,
            paneSessionName: "graftty-aabbccdd"
        )
        let member = TeamListMember(
            name: "feature",
            branch: "feature",
            worktreePath: "/repo/feature",
            isMainWorktree: false,
            isRunning: true,
            agents: [agent]
        )
        let document = TeamListDocument(team: "repo", members: [member])

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(TeamListDocument.self, from: data)

        #expect(decoded == document)
        #expect(decoded.members[0].agents == [agent])
    }

    private func presence(
        runtime: TeamHookRuntime,
        sessionID: String,
        displayName: String? = nil,
        registeredAt: TimeInterval,
        isSubagent: Bool = false
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/feature",
            runtime: runtime,
            paneSessionName: "graftty-\(sessionID)",
            pid: 100,
            processStartTimeMicroseconds: 1_000,
            registeredAt: Date(timeIntervalSince1970: registeredAt),
            runtimeSessionID: sessionID,
            nativeDisplayName: displayName,
            isSubagent: isSubagent
        )
    }
}
