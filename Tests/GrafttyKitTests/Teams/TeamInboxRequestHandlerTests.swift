import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team Inbox Request Handler")
struct TeamInboxRequestHandlerTests {
    private static func makeHandler(
        inbox: TeamInbox,
        templateProvider: @escaping () -> String = { "" },
        sessionPromptRenderer: ((TeamView, TeamMember) -> String?)? = nil,
        onStop: (@Sendable (String, String, String, String?) -> Void)? = nil,
        onSessionStart: (@Sendable (String, String, String, String?) -> Void)? = nil,
        onPostToolUse: (@Sendable (String, String, String, String?) -> Void)? = nil,
        automaticDeliveryOwner: (@Sendable (
            _ teamID: String,
            _ worktree: String,
            _ runtime: TeamHookRuntime,
            _ paneSessionName: String?
        ) -> Bool)? = nil
    ) -> TeamInboxRequestHandler {
        TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: TeamEventDispatcher(
                inbox: inbox,
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: templateProvider
            ),
            sessionPromptRenderer: sessionPromptRenderer,
            onStop: onStop,
            onSessionStart: onSessionStart,
            onPostToolUse: onPostToolUse,
            automaticDeliveryOwner: automaticDeliveryOwner
        )
    }

    @Test func sendAppendsAddressedMessage() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        )

        let delivery = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "please review",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(delivery.recipient.name == "alice")
        #expect(delivery.message.from.member == "main")
        #expect(delivery.message.to.member == "alice")
        #expect(delivery.message.body == "please review")
    }

    @Test func broadcastExcludesSenderAndDeliversToAllOthers() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice", "bob"])
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001", "0002"]), now: { Self.fixedDate })
        )

        let deliveries = try handler.broadcast(
            callerWorktree: "/repo/.worktrees/alice",
            text: "heads up",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(deliveries.map { $0.recipient.name }.sorted() == ["bob", "main"])
        #expect(deliveries.allSatisfy { $0.message.from.member == "alice" })
        // Phase 2 dispatches per-recipient so each row has a fresh ID; the
        // legacy `batchID` shared marker is no longer guaranteed.
    }

    @Test func sendRejectsUnknownRecipient() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let handler = Self.makeHandler(inbox: TeamInbox(rootDirectory: root))

        #expect(throws: TeamInboxRequestError.self) {
            try handler.send(
                callerWorktree: "/repo",
                recipient: "nobody",
                text: "hello",
                priority: .normal,
                repos: [repo],
                teamsEnabled: true
            )
        }
    }

    @Test func sessionStartIncludesRenderedConfiguredPrompt() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root),
            sessionPromptRenderer: { _, viewer in
                "Configured policy for \(viewer.name)"
            }
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .sessionStart,
            sessionID: "session-1",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(output.contains("Configured policy for alice"))
        #expect(output.contains("Graftty Agent Team session context"))
    }

    @Test func postToolUseDoesNotAdvanceCursorPastUndeliveredNormalMessage() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let ids = Self.fixedIDs(["0001", "0002"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: ids, now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "normal first",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )
        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent second",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        let postToolOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "session-1",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(postToolOutput.contains("urgent second"))
        #expect(!postToolOutput.contains("normal first"))
        let cursor = try inbox.cursor(teamID: "/repo", sessionID: "session-1")
        #expect(cursor?.lastSeenID == nil)

        // Stop hook in both runtimes only accepts top-level fields,
        // so the rendered output is `{}` regardless of the inbox
        // state — the previously-undelivered normal message stays
        // pending and is replayed at the next SessionStart's inbox
        // dump (or via the asyncRewake watcher on Claude).
        let stopOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .stop,
            sessionID: "session-1",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )
        #expect(stopOutput == "{}")

        // Critical side-effect contract: because Stop emits `{}`
        // and never delivers content to the agent, it must NOT
        // advance the cursor. Advancing it would silently mark
        // pending messages "delivered" and bury them past the next
        // SessionStart's replay — every Stop firing during an idle
        // period would walk the cursor forward over messages the
        // agent never saw. The cursor stays nil here for the same
        // reason it stayed nil after PostToolUse skipped the
        // normal-priority message above.
        let cursorAfterStop = try inbox.cursor(teamID: "/repo", sessionID: "session-1")
        #expect(cursorAfterStop?.lastSeenID == nil)
    }

    @Test("Owner PostToolUse renders urgent inbox messages and advances delivery state.")
    func ownerPostToolUseRendersUrgentMessagesAndAdvancesCursor() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(
            inbox: inbox,
            automaticDeliveryOwner: { _, _, _, paneSessionName in
                paneSessionName == "graftty-owner"
            }
        )

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent body",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "owner",
            paneSessionName: "graftty-owner",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(output.contains("urgent body"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "owner")?.lastSeenID == "0001")
        #expect(try inbox.worktreeWatermark(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice"
        )?.lastDeliveredToAnySessionID == "0001")
    }

    @Test("Non-owner PostToolUse does not render urgent inbox messages or advance delivery state.")
    func nonOwnerPostToolUseDoesNotRenderOrAdvance() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(
            inbox: inbox,
            automaticDeliveryOwner: { _, _, _, paneSessionName in
                paneSessionName == "graftty-owner"
            }
        )

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent body",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "secondary",
            paneSessionName: "graftty-secondary",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(!output.contains("urgent body"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary")?.lastSeenID == nil)
        #expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
    }

    @Test("PostToolUse without ownership closure remains backward-compatible.")
    func postToolUseWithoutOwnershipClosureStillRendersAndAdvances() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent body",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "legacy",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(output.contains("urgent body"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "legacy")?.lastSeenID == "0001")
        #expect(try inbox.worktreeWatermark(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice"
        )?.lastDeliveredToAnySessionID == "0001")
    }

    @Test("Resolver-gated secondary Claude PostToolUse does not render or advance.")
    func resolverGatedSecondaryClaudePostToolUseDoesNotRenderOrAdvance() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let records = [
            Self.presenceRecord(
                runtime: .claude,
                sessionName: "graftty-owner",
                pid: 101,
                start: 10_001,
                registeredAt: 10
            ),
            Self.presenceRecord(
                runtime: .claude,
                sessionName: "graftty-secondary",
                pid: 102,
                start: 10_002,
                registeredAt: 20
            ),
        ]
        let resolver = TeamDeliveryOwnershipResolver(
            records: { records },
            liveness: TestDeliveryLiveness(
                liveSessions: ["graftty-owner", "graftty-secondary"],
                processStartTimes: [101: 10_001, 102: 10_002]
            )
        )
        let handler = Self.makeHandler(
            inbox: inbox,
            automaticDeliveryOwner: { teamID, worktree, runtime, paneSessionName in
                guard let paneSessionName else { return false }
                let key = TeamDeliveryOwnerKey(teamID: teamID, worktree: worktree, runtime: runtime)
                return resolver.owner(for: key)?.paneSessionName == paneSessionName
            }
        )

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent body",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .claude,
            event: .postToolUse,
            sessionID: "secondary",
            paneSessionName: "graftty-secondary",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(!output.contains("urgent body"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary")?.lastSeenID == nil)
        #expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
    }

    @Test("@spec TEAM-IDLE-2.5: Stop hook fires onStop side-effect callback before returning {}.")
    func stopHookFiresOnStopCallback() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let recorder = OnStopCallRecorder()
        let handler = Self.makeHandler(
            inbox: inbox,
            onStop: { team, worktree, runtime, _ in
                recorder.append(team: team, worktree: worktree, runtime: runtime)
            }
        )

        _ = try handler.send(
            callerWorktree: "/repo", recipient: "alice", text: "hi",
            priority: .normal, repos: [repo], teamsEnabled: true
        )
        let stopOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice", runtime: .codex,
            event: .stop, sessionID: "s-1", paneSessionName: nil,
            repos: [repo], teamsEnabled: true
        )

        #expect(stopOutput == "{}")
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].worktree == "/repo/.worktrees/alice")
        #expect(recorder.calls[0].runtime == "codex")
    }

    @Test("@spec TEAM-IDLE-2.5: Stop hook with no onStop callback still returns {} (back-compat).")
    func stopHookWithoutCallbackStillWorks() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)
        let stopOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice", runtime: .codex,
            event: .stop, sessionID: "s-1", paneSessionName: nil,
            repos: [repo], teamsEnabled: true
        )
        #expect(stopOutput == "{}")
    }

    @Test("SessionStart hook fires onSessionStart callback before returning rendered context.")
    func sessionStartFiresOnSessionStartCallback() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let recorder = OnStopCallRecorder()
        let handler = Self.makeHandler(
            inbox: inbox,
            onSessionStart: { team, worktree, runtime, _ in
                recorder.append(team: team, worktree: worktree, runtime: runtime)
            }
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice", runtime: .codex,
            event: .sessionStart, sessionID: "s-1", paneSessionName: nil,
            repos: [repo], teamsEnabled: true
        )

        // Callback fired exactly once with correct coordinates.
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].team == "/repo")
        #expect(recorder.calls[0].worktree == "/repo/.worktrees/alice")
        #expect(recorder.calls[0].runtime == "codex")
        // Rendered output is unchanged — callback is a side-effect only.
        #expect(output.contains("Graftty Agent Team session context"))
    }

    @Test("PostToolUse hook fires onPostToolUse callback before returning rendered context.")
    func postToolUseFiresOnPostToolUseCallback() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let recorder = OnStopCallRecorder()
        let handler = Self.makeHandler(
            inbox: inbox,
            onPostToolUse: { team, worktree, runtime, _ in
                recorder.append(team: team, worktree: worktree, runtime: runtime)
            }
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice", runtime: .codex,
            event: .postToolUse, sessionID: "s-1", paneSessionName: nil,
            repos: [repo], teamsEnabled: true
        )

        // Callback fired exactly once with correct coordinates.
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].team == "/repo")
        #expect(recorder.calls[0].worktree == "/repo/.worktrees/alice")
        #expect(recorder.calls[0].runtime == "codex")
        // Rendered output is unchanged — callback is a side-effect only.
        // No urgent messages in inbox, so output is the "nothing pending" response.
        #expect(!output.isEmpty)
    }

    @Test("Non-owner PostToolUse still fires callback before skipping automatic delivery.")
    func nonOwnerPostToolUseFiresCallbackWithoutAdvancingDelivery() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let recorder = OnStopCallRecorder()
        let handler = Self.makeHandler(
            inbox: inbox,
            onPostToolUse: { team, worktree, runtime, _ in
                recorder.append(team: team, worktree: worktree, runtime: runtime)
            },
            automaticDeliveryOwner: { _, _, _, paneSessionName in
                paneSessionName == "graftty-owner"
            }
        )

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent body",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .postToolUse,
            sessionID: "secondary",
            paneSessionName: "graftty-secondary",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].team == "/repo")
        #expect(recorder.calls[0].worktree == "/repo/.worktrees/alice")
        #expect(recorder.calls[0].runtime == "codex")
        #expect(!output.contains("urgent body"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary")?.lastSeenID == nil)
        #expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
    }

    @Test("@spec TEAM-IDLE-2.9: hook(...) forwards paneSessionName into the onStop callback.")
    func hookForwardsPaneSessionNameToOnStop() throws {
        final class Captured: @unchecked Sendable {
            var paneSessionName: String? = "<unset>"
        }
        let captured = Captured()
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(
            inbox: inbox,
            onStop: { _, _, _, paneSessionName in
                captured.paneSessionName = paneSessionName
            }
        )

        _ = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .stop,
            sessionID: nil,
            paneSessionName: "graftty-abc12345",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(captured.paneSessionName == "graftty-abc12345")
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static func fixedIDs(_ values: [String]) -> () -> String {
        var ids = values
        return {
            guard !ids.isEmpty else { return "overflow" }
            return ids.removeFirst()
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-team-inbox-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func presenceRecord(
        runtime: TeamHookRuntime,
        sessionName: String,
        pid: Int32,
        start: Int64,
        registeredAt: TimeInterval
    ) -> TeamPresenceRecord {
        TeamPresenceRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            runtime: runtime,
            paneSessionName: sessionName,
            pid: pid,
            processStartTimeMicroseconds: start,
            registeredAt: Date(timeIntervalSince1970: registeredAt)
        )
    }
}

final class OnStopCallRecorder: @unchecked Sendable {
    struct Call { let team: String; let worktree: String; let runtime: String }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    func append(team: String, worktree: String, runtime: String) {
        lock.lock(); defer { lock.unlock() }
        calls.append(.init(team: team, worktree: worktree, runtime: runtime))
    }
}

private struct TestDeliveryLiveness: TeamDeliveryLivenessChecking {
    var liveSessions: Set<String>
    var processStartTimes: [Int32: Int64]

    func isLivePaneSession(_ sessionName: String) -> Bool {
        liveSessions.contains(sessionName)
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        processStartTimes[pid]
    }
}
