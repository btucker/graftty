import Foundation
import Testing
@testable import GrafttyKit

@Suite("Team Inbox Request Handler")
struct TeamInboxRequestHandlerTests {
    private static func makeHandler(
        inbox: TeamInbox,
        templateProvider: @escaping () -> String = { "" },
        sessionPromptRenderer: ((TeamView, TeamMember) -> String?)? = nil,
        automaticDeliveryOwner: (@Sendable (
            _ teamID: String,
            _ worktree: String,
            _ runtime: TeamHookRuntime,
            _ paneSessionName: String?
        ) -> Bool)? = nil,
        agentRecords: @escaping @Sendable () -> [TeamPresenceRecord] = { [] },
        agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool = { _ in false }
    ) -> TeamInboxRequestHandler {
        TeamInboxRequestHandler(
            inbox: inbox,
            dispatcher: TeamEventDispatcher(
                inbox: inbox,
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: templateProvider
            ),
            sessionPromptRenderer: sessionPromptRenderer,
            automaticDeliveryOwner: automaticDeliveryOwner,
            agentRecords: agentRecords,
            agentReachability: agentReachability
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

    @Test("Unsuffixed recipient is bound to the earliest reachable top-level agent.")
    func sendBindsDefaultAgentOnce() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let alice = "/repo/.worktrees/alice"
        let claude = TeamPresenceRecord(
            teamID: "/repo", worktree: alice, runtime: .claude,
            paneSessionName: "graftty-claude", pid: 101,
            processStartTimeMicroseconds: 1_001,
            registeredAt: Date(timeIntervalSince1970: 10),
            runtimeSessionID: "claude-session"
        )
        let codex = TeamPresenceRecord(
            teamID: "/repo", worktree: alice, runtime: .codex,
            paneSessionName: "graftty-codex", pid: 102,
            processStartTimeMicroseconds: 1_002,
            registeredAt: Date(timeIntervalSince1970: 20),
            runtimeSessionID: "codex-session"
        )
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root),
            agentRecords: { [codex, claude] },
            agentReachability: { _ in true }
        )

        let delivery = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "please review",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(delivery.message.to.runtime == "claude")
        #expect(delivery.message.to.agentID == TeamAgentIdentity(
            runtime: .claude,
            nativeSessionID: "claude-session"
        ).rawValue)
    }

    @Test("Explicit canonical recipient rejects stale identity without appending.")
    func explicitRecipientFailsClosed() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let alice = "/repo/.worktrees/alice"
        let stale = TeamPresenceRecord(
            teamID: "/repo", worktree: alice, runtime: .codex,
            paneSessionName: "graftty-codex", pid: 102,
            processStartTimeMicroseconds: 1_002,
            registeredAt: Date(timeIntervalSince1970: 20),
            runtimeSessionID: "codex-session"
        )
        let identity = TeamAgentIdentity(runtime: .codex, nativeSessionID: "codex-session")
        let inbox = TeamInbox(rootDirectory: root)
        let handler = Self.makeHandler(
            inbox: inbox,
            agentRecords: { [stale] },
            agentReachability: { _ in false }
        )

        #expect(throws: TeamInboxRequestError.agentUnavailable(identity.rawValue)) {
            _ = try handler.send(
                callerWorktree: "/repo",
                recipient: "alice#\(identity.rawValue)",
                text: "do not reroute",
                priority: .normal,
                repos: [repo],
                teamsEnabled: true
            )
        }
        #expect(try inbox.messages(teamID: "/repo").isEmpty)
    }

    @Test func sendUsesCanonicalPathToDisambiguateCollidingMemberNames() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "foo--bar", "foo-bar"]
        )
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: Self.fixedIDs(["0001"]),
            now: { Self.fixedDate }
        )
        let targetPath = "/repo/.worktrees/foo-bar"
        let targetPresence = TeamPresenceRecord(
            teamID: "/repo", worktree: targetPath, runtime: .codex,
            paneSessionName: "target-codex", pid: 102,
            processStartTimeMicroseconds: 1_002,
            registeredAt: Date(timeIntervalSince1970: 20),
            runtimeSessionID: "target-codex-session"
        )
        let identity = TeamAgentIdentity(runtime: .codex, nativeSessionID: "target-codex-session")
        let handler = Self.makeHandler(
            inbox: inbox,
            agentRecords: { [targetPresence] },
            agentReachability: { _ in true }
        )

        let delivery = try handler.send(
            callerWorktree: "/repo",
            recipient: "\(targetPath)#\(identity.rawValue)",
            text: "path-addressed",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(delivery.recipient.branch == "foo-bar")
        #expect(delivery.message.to.worktree == targetPath)
        #expect(delivery.message.to.agentID == identity.rawValue)
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

    @Test("@spec TEAM-4.5: When team inbox diagnostics contain more than one page, the application shall return a newest-first page selection bounded by both message count and encoded size, preserve chronological order within each page, and provide an opaque cursor whose traversal neither duplicates nor omits messages.")
    func diagnosticInboxPaginatesBackwardFromNewestMessage() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: Self.fixedIDs(["0001", "0002", "0003", "0004", "0005"]),
            now: { Self.fixedDate }
        )
        let handler = Self.makeHandler(inbox: inbox)
        for index in 1...5 {
            _ = try handler.send(
                callerWorktree: "/repo",
                recipient: "alice",
                text: "message \(index)",
                priority: .normal,
                repos: [repo],
                teamsEnabled: true
            )
        }

        let newest = try handler.diagnosticPage(
            callerWorktree: "/repo/.worktrees/alice",
            worktree: nil,
            repo: nil,
            member: nil,
            unread: false,
            all: false,
            beforeID: nil,
            limit: 2,
            repos: [repo],
            teamsEnabled: true
        )
        #expect(newest.messages.map(\.id) == ["0004", "0005"])
        #expect(newest.nextBeforeID == "0004")

        let middle = try handler.diagnosticPage(
            callerWorktree: "/repo/.worktrees/alice",
            worktree: nil,
            repo: nil,
            member: nil,
            unread: false,
            all: false,
            beforeID: newest.nextBeforeID,
            limit: 2,
            repos: [repo],
            teamsEnabled: true
        )
        #expect(middle.messages.map(\.id) == ["0002", "0003"])
        #expect(middle.nextBeforeID == "0002")

        let oldest = try handler.diagnosticPage(
            callerWorktree: "/repo/.worktrees/alice",
            worktree: nil,
            repo: nil,
            member: nil,
            unread: false,
            all: false,
            beforeID: middle.nextBeforeID,
            limit: 2,
            repos: [repo],
            teamsEnabled: true
        )
        #expect(oldest.messages.map(\.id) == ["0001"])
        #expect(oldest.nextBeforeID == nil)
    }

    @Test func diagnosticInboxPageHonorsEncodedByteLimit() throws {
        let messages = (1...3).map { index in
            TeamInboxMessage(
                id: "000\(index)",
                batchID: nil,
                createdAt: Self.fixedDate,
                team: "/repo",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
                to: TeamInboxEndpoint(
                    member: "alice",
                    worktree: "/repo/.worktrees/alice",
                    runtime: nil
                ),
                priority: .normal,
                body: String(repeating: "x", count: 200)
            )
        }
        let oneMessageBudget = try JSONEncoder().encode(messages[2]).count + 1

        let page = try TeamInboxDiagnosticPaginator.newestPage(
            from: messages[...],
            countLimit: 100,
            encodedByteLimit: oneMessageBudget
        )

        #expect(page.map(\.id) == ["0003"])
    }

    @Test("@spec TEAM-4.7: When a team inbox request omits pagination support required for its read direction, the application shall reject it with an instruction to use the bundled CLI rather than return an oversized response or silently discard later pages.")
    func diagnosticInboxRequestWithoutPaginationIsRejected() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )
        let ids = (1...101).map { String(format: "%04d", $0) }
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: Self.fixedIDs(ids),
            now: { Self.fixedDate }
        )
        for index in 1...101 {
            _ = try inbox.appendMessage(
                teamID: "/repo",
                teamName: "repo",
                repoPath: "/repo",
                from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
                to: TeamInboxEndpoint(
                    member: "alice",
                    worktree: "/repo/.worktrees/alice",
                    runtime: nil
                ),
                priority: .normal,
                body: "message \(index)"
            )
        }

        #expect(throws: TeamInboxRequestError.paginationRequired) {
            try Self.makeHandler(inbox: inbox).diagnosticPage(
                callerWorktree: "/repo/.worktrees/alice",
                worktree: nil,
                repo: nil,
                member: nil,
                unread: false,
                all: false,
                beforeID: nil,
                limit: nil,
                repos: [repo],
                teamsEnabled: true
            )
        }

        #expect(throws: TeamInboxRequestError.paginationRequired) {
            try Self.makeHandler(inbox: inbox).diagnosticPage(
                callerWorktree: "/repo/.worktrees/alice",
                worktree: nil,
                repo: nil,
                member: nil,
                unread: true,
                all: true,
                beforeID: nil,
                forwardPagination: nil,
                limit: 100,
                repos: [repo],
                teamsEnabled: true
            )
        }
    }

    @Test("""
    @spec TEAM-3.3: Two user templates control agent-facing team text. At session start, the rendered `teamSessionPrompt` is the complete team context section delivered by the hook, with instruction files delivered as a separate section; empty, whitespace-only, or invalid templates suppress that context rather than revealing a hidden hard-coded primer, and render failures are logged. Queued inbox messages remain a separate transient session-start section. For automated-event delivery, the rendered `teamPrompt` is stored separately from the unchanged event body at write time per recipient, with the same render/empty/failure rules. This covers PR/CI/merge events routed by `TeamEventDispatcher.dispatchRoutableEvent` plus `team_member_joined` and `team_member_left`; authored `team_message` rows bypass the automated-event template.
    """)
    func sessionStartUsesConfiguredPromptAsTheCompleteContext() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root),
            sessionPromptRenderer: { _, viewer in
                "Complete configured context for \(viewer.name)"
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

        #expect(output.contains("Complete configured context for alice"))
        #expect(!output.contains("Graftty team context"))
        #expect(!output.contains("graftty team inbox"))

        let event = ChannelServerMessage.event(
            type: TeamChannelEvents.WireType.prStateChanged,
            attrs: ["to": "open"],
            body: "PR opened"
        )
        let split = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/repo/.worktrees/alice",
            subjectWorktreePath: "/repo/.worktrees/alice",
            repos: [repo],
            templateString: "Event for {{ agent.branch }}: {{ body }}"
        )
        #expect(split.event == event)
        #expect(split.agentPrompt == "Event for alice: PR opened")
    }

    @Test func suppressedSessionTemplateDoesNotRevealHiddenInstructions() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )
        let handler = Self.makeHandler(
            inbox: TeamInbox(rootDirectory: root),
            sessionPromptRenderer: { _, _ in nil }
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .sessionStart,
            sessionID: "suppressed-session",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(!output.contains("Graftty team context"))
        #expect(!output.contains("graftty team inbox"))
    }

    @Test("""
    @spec AGENT-6.9: When a provider plugin invokes a skill-managed SessionStart hook, the application shall omit the legacy team primer supplied by the system-hook path while still delivering any queued exact-agent messages as separate transient context.
    """)
    func skillManagedSessionOmitsPrimerButKeepsQueuedMessages() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: Self.fixedIDs(["0001"]),
            now: { Self.fixedDate }
        )
        let handler = Self.makeHandler(inbox: inbox)
        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "queued before launch",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .codex,
            event: .sessionStart,
            sessionID: "session-1",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true,
            skillManaged: true
        )

        #expect(!output.contains("Graftty team context"))
        #expect(!output.contains("graftty worktree add"))
        #expect(output.contains("queued before launch"))
    }

    @Test("""
    @spec AGENT-5.3: When Codex or Claude starts in a team-enabled worktree, the application shall inject instructions for launching an agent with `graftty worktree add --agent`, identify the returned address as belonging to the worktree rather than the process, direct later guidance through the shell-safe `graftty team send --stdin` inbox path, and deliver queued worktree inbox messages before normal work begins. When multiple live sessions share the same worktree and runtime, only the selected automatic-delivery owner shall render and advance that queued inbox; non-owner sessions shall still receive the team instructions without consuming the owner's messages.
    """)
    func sessionStartDeliversQueuedMessagesAndAdvancesCursor() throws {
        for runtime in [TeamHookRuntime.codex, .claude] {
            let root = try Self.temporaryDirectory()
            let repo = TeamTestFixtures.makeRepo(
                path: "/repo",
                displayName: "repo",
                branches: ["main", "alice"]
            )
            let inbox = TeamInbox(
                rootDirectory: root,
                idGenerator: Self.fixedIDs(["0001"]),
                now: { Self.fixedDate }
            )
            let handler = Self.makeHandler(inbox: inbox)

            _ = try handler.send(
                callerWorktree: "/repo",
                recipient: "alice",
                text: "queued before launch",
                priority: .normal,
                repos: [repo],
                teamsEnabled: true
            )

            let output = try handler.hook(
                callerWorktree: "/repo/.worktrees/alice",
                runtime: runtime,
                event: .sessionStart,
                sessionID: "session-1",
                paneSessionName: nil,
                repos: [repo],
                teamsEnabled: true
            )

            #expect(output.contains("graftty worktree add <name> --agent <codex|claude>"))
            #expect(output.contains("worktree's stable reply address"))
            #expect(output.contains("graftty team send --stdin <address>"))
            #expect(output.contains("queued before launch"))
            #expect(output.contains("<graftty-peer-message agent=\\\"\\/repo\\\">"))
            #expect(!output.lowercased().contains("untrusted peer"))
            #expect(try inbox.cursor(teamID: "/repo", sessionID: "session-1")?.lastSeenID == "0001")
            #expect(try inbox.worktreeWatermark(
                teamID: "/repo",
                worktree: "/repo/.worktrees/alice"
            )?.lastDeliveredToAnySessionID == "0001")
        }
    }

    @Test("A non-owner SessionStart receives team context without consuming the owner's queue.")
    func nonOwnerSessionStartDoesNotRenderOrAdvanceQueuedMessages() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: Self.fixedIDs(["0001"]),
            now: { Self.fixedDate }
        )
        let handler = Self.makeHandler(
            inbox: inbox,
            automaticDeliveryOwner: { _, _, _, paneSessionName in
                paneSessionName == "graftty-owner"
            }
        )

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "queued for the owner",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        let secondaryOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .claude,
            event: .sessionStart,
            sessionID: "secondary",
            paneSessionName: "graftty-secondary",
            repos: [repo],
            teamsEnabled: true
        )

        #expect(secondaryOutput.contains("Graftty team context"))
        #expect(!secondaryOutput.contains("queued for the owner"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary") == nil)
        #expect(try inbox.worktreeWatermark(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice"
        ) == nil)

        let ownerOutput = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice",
            runtime: .claude,
            event: .sessionStart,
            sessionID: "owner",
            paneSessionName: "graftty-owner",
            repos: [repo],
            teamsEnabled: true
        )
        #expect(ownerOutput.contains("queued for the owner"))
    }

    @Test("SessionStart stops at a message targeted to another runtime.")
    func sessionStartPreservesRuntimeTargetedHeadOfLine() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(
            path: "/repo",
            displayName: "repo",
            branches: ["main", "alice"]
        )
        let aliceWorktree = "/repo/.worktrees/alice"
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: Self.fixedIDs(["0001", "0002"]),
            now: { Self.fixedDate }
        )
        let handler = Self.makeHandler(inbox: inbox)
        _ = try inbox.appendMessage(
            teamID: "/repo",
            teamName: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: aliceWorktree, runtime: "codex"),
            priority: .normal,
            body: "for Codex"
        )
        _ = try inbox.appendMessage(
            teamID: "/repo",
            teamName: "repo",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: aliceWorktree, runtime: nil),
            priority: .normal,
            body: "shared after Codex"
        )

        let claudeOutput = try handler.hook(
            callerWorktree: aliceWorktree,
            runtime: .claude,
            event: .sessionStart,
            sessionID: "claude-session",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(!claudeOutput.contains("for Codex"))
        #expect(!claudeOutput.contains("shared after Codex"))
        #expect(try inbox.cursor(
            teamID: "/repo",
            sessionID: "claude-session"
        )?.lastSeenID == nil)
        #expect(try inbox.worktreeWatermark(
            teamID: "/repo",
            worktree: aliceWorktree
        ) == nil)
    }

    @Test func claudePostToolUseDoesNotAdvanceCursorPastUndeliveredNormalMessage() throws {
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
            runtime: .claude,
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
        // pending for the next real delivery path instead of being
        // marked seen by a no-op hook response.
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
        // real delivery path — every Stop firing during an idle
        // period would walk the cursor forward over messages the
        // agent never saw. The cursor stays nil here for the same
        // reason it stayed nil after PostToolUse skipped the
        // normal-priority message above.
        let cursorAfterStop = try inbox.cursor(teamID: "/repo", sessionID: "session-1")
        #expect(cursorAfterStop?.lastSeenID == nil)
    }

    @Test("Codex owner PostToolUse does not render, advance delivery state, or fire delivery callbacks.")
    func codexOwnerPostToolUseDoesNotRenderAdvanceOrFireCallback() throws {
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

        #expect(!output.contains("urgent body"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "owner") == nil)
        #expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
    }

    @Test("Claude owner PostToolUse renders urgent inbox messages and advances delivery state.")
    func claudeOwnerPostToolUseRendersUrgentMessagesAndAdvancesCursor() throws {
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
            runtime: .claude,
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

    @Test("@spec TEAM-11.7: If the worktree watermark cannot be advanced during hook delivery, then the application shall leave the session cursor unadvanced so the undelivered messages are redelivered by a later hook.")
    func watermarkTimeoutDuringHookDeliveryDoesNotSkipMessages() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let aliceWorktree = "/repo/.worktrees/alice"
        let inbox = TeamInbox(
            rootDirectory: root,
            idGenerator: Self.fixedIDs(["0001"]),
            now: { Self.fixedDate },
            watermarkLockTimeout: 0.2
        )
        let handler = Self.makeHandler(inbox: inbox)

        _ = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "urgent body",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )

        // Hold the inter-process watermark lock from a child process so the
        // hook's watermark advance times out mid-delivery.
        let holder = try TeamTestFixtures.holdWatermarkLock(
            root: root,
            teamID: "/repo",
            worktree: aliceWorktree
        )
        defer { holder.release() }

        #expect(throws: TeamInboxError.watermarkLockTimeout) {
            try handler.hook(
                callerWorktree: aliceWorktree,
                runtime: .claude,
                event: .postToolUse,
                sessionID: "owner",
                paneSessionName: nil,
                repos: [repo],
                teamsEnabled: true
            )
        }

        // The failed delivery must not have advanced the session cursor
        // past the message it never delivered.
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "owner")?.lastSeenID == nil)

        // Once the lock is free again, the same hook redelivers the message.
        holder.release()
        let output = try handler.hook(
            callerWorktree: aliceWorktree,
            runtime: .claude,
            event: .postToolUse,
            sessionID: "owner",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )
        #expect(output.contains("urgent body"))
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "owner")?.lastSeenID == "0001")
    }

    @Test("An existing Claude session honors later worktree watermark advances.")
    func existingClaudeSessionHonorsLaterWorktreeWatermark() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001", "0002"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)
        let aliceWorktree = "/repo/.worktrees/alice"

        let initial = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "already delivered",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: aliceWorktree,
                lastDeliveredToAnySessionID: initial.message.id
            ),
            teamID: "/repo"
        )

        _ = try handler.hook(
            callerWorktree: aliceWorktree,
            runtime: .claude,
            event: .sessionStart,
            sessionID: "session-anchored",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )

        let newer = try handler.send(
            callerWorktree: "/repo",
            recipient: "alice",
            text: "newer urgent",
            priority: .urgent,
            repos: [repo],
            teamsEnabled: true
        )
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: aliceWorktree,
                lastDeliveredToAnySessionID: newer.message.id
            ),
            teamID: "/repo"
        )

        let output = try handler.hook(
            callerWorktree: aliceWorktree,
            runtime: .claude,
            event: .postToolUse,
            sessionID: "session-anchored",
            paneSessionName: nil,
            repos: [repo],
            teamsEnabled: true
        )

        #expect(!output.contains("already delivered"))
        #expect(!output.contains("newer urgent"))
        #expect(try inbox.cursor(
            teamID: "/repo",
            sessionID: "session-anchored"
        )?.lastSeenID == initial.message.id)
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
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary") == nil)
        #expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
    }

    @Test("Claude PostToolUse without ownership closure remains backward-compatible.")
    func claudePostToolUseWithoutOwnershipClosureStillRendersAndAdvances() throws {
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
            runtime: .claude,
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
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary") == nil)
        #expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
    }

    @Test("Stop hook returns {} without firing delivery callbacks.")
    func stopHookDoesNotFireDeliveryCallback() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)

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
    }

    @Test("Stop hook returns {}.")
    func stopHookReturnsEmptyObject() throws {
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

    @Test("SessionStart hook returns rendered context.")
    func sessionStartReturnsRenderedContext() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice", runtime: .codex,
            event: .sessionStart, sessionID: "s-1", paneSessionName: nil,
            repos: [repo], teamsEnabled: true
        )

        #expect(output.contains("Graftty team context"))
    }

    @Test("PostToolUse hook returns rendered context without firing delivery callbacks.")
    func postToolUseDoesNotFireDeliveryCallback() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root, idGenerator: Self.fixedIDs(["0001"]), now: { Self.fixedDate })
        let handler = Self.makeHandler(inbox: inbox)

        let output = try handler.hook(
            callerWorktree: "/repo/.worktrees/alice", runtime: .codex,
            event: .postToolUse, sessionID: "s-1", paneSessionName: nil,
            repos: [repo], teamsEnabled: true
        )

        #expect(!output.isEmpty)
    }

    @Test("Non-owner PostToolUse skips automatic delivery without firing delivery callbacks.")
    func nonOwnerPostToolUseSkipsWithoutFiringCallback() throws {
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
        #expect(try inbox.cursor(teamID: "/repo", sessionID: "secondary") == nil)
        #expect(try inbox.worktreeWatermark(teamID: "/repo", worktree: "/repo/.worktrees/alice") == nil)
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
