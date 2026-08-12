import Foundation
import GrafttyProtocol

public enum TeamInboxRequestError: Error, Equatable, CustomStringConvertible {
    case teamModeDisabled
    case callerNotTracked
    case notInTeam
    case senderNotInTeam
    case recipientNotFound(name: String, available: [String])
    case agentNotFound(String)
    case agentUnavailable(String)
    case paginationRequired
    case paginationCursorNotFound(String)

    public var description: String {
        switch self {
        case .teamModeDisabled:
            return "team mode is disabled"
        case .callerNotTracked:
            return "not inside a tracked worktree"
        case .notInTeam:
            return "not in a team"
        case .senderNotInTeam:
            return "internal error: caller not in resolved team"
        case .recipientNotFound(let name, let available):
            return "\(name) is not a teammate of this worktree; current teammates: \(available.joined(separator: ", "))"
        case .agentNotFound(let id):
            return "team agent not found: \(id)"
        case .agentUnavailable(let id):
            return "team agent is no longer reachable: \(id)"
        case .paginationRequired:
            return "team inbox request is missing pagination support; use the CLI bundled with this Graftty version"
        case .paginationCursorNotFound(let id):
            return "team inbox pagination cursor no longer exists: \(id)"
        }
    }
}

public struct TeamInboxDiagnosticPage: Sendable, Equatable {
    public static let defaultLimit = 100
    public static let maximumLimit = 500
    public static let maximumEncodedBytes = 8 * 1024 * 1024

    public let messages: [TeamInboxMessage]
    public let nextBeforeID: String?
    public let nextAfterID: String?
    public let snapshotThroughID: String?

    public init(
        messages: [TeamInboxMessage],
        nextBeforeID: String? = nil,
        nextAfterID: String? = nil,
        snapshotThroughID: String? = nil
    ) {
        self.messages = messages
        self.nextBeforeID = nextBeforeID
        self.nextAfterID = nextAfterID
        self.snapshotThroughID = snapshotThroughID
    }
}

enum TeamInboxDiagnosticPaginator {
    private static func boundedPage<S: Sequence>(
        from candidates: S,
        countLimit: Int,
        encodedByteLimit: Int
    ) throws -> [TeamInboxMessage] where S.Element == TeamInboxMessage {
        let encoder = JSONEncoder()
        var messages: [TeamInboxMessage] = []
        var encodedBytes = 0

        for message in candidates {
            if !messages.isEmpty, messages.count >= countLimit {
                break
            }
            let separatorBytes = messages.isEmpty ? 0 : 1
            let messageBytes = try encoder.encode(message).count + separatorBytes
            if !messages.isEmpty, encodedBytes + messageBytes > encodedByteLimit {
                break
            }
            messages.append(message)
            encodedBytes += messageBytes
        }

        return messages
    }

    static func oldestPage(
        from candidates: ArraySlice<TeamInboxMessage>,
        countLimit: Int,
        encodedByteLimit: Int
    ) throws -> [TeamInboxMessage] {
        try boundedPage(
            from: candidates,
            countLimit: countLimit,
            encodedByteLimit: encodedByteLimit
        )
    }

    static func newestPage(
        from candidates: ArraySlice<TeamInboxMessage>,
        countLimit: Int,
        encodedByteLimit: Int
    ) throws -> [TeamInboxMessage] {
        let newestFirst = try boundedPage(
            from: candidates.reversed(),
            countLimit: countLimit,
            encodedByteLimit: encodedByteLimit
        )
        return Array(newestFirst.reversed())
    }
}

public struct TeamInboxDelivery: Sendable, Equatable {
    public let recipient: TeamMember
    public let message: TeamInboxMessage

    public init(recipient: TeamMember, message: TeamInboxMessage) {
        self.recipient = recipient
        self.message = message
    }
}

public final class TeamInboxRequestHandler {
    private let inbox: TeamInbox
    private let dispatcher: TeamEventDispatcher
    private let sessionPromptRenderer: ((TeamView, TeamMember) -> String?)?
    private let automaticDeliveryOwner: (@Sendable (
        _ teamID: String,
        _ worktree: String,
        _ runtime: TeamHookRuntime,
        _ paneSessionName: String?
    ) -> Bool)?
    private let agentRecords: @Sendable () -> [TeamPresenceRecord]
    private let agentReachability: @Sendable (TeamPresenceRecord) -> Bool

    public init(
        inbox: TeamInbox,
        dispatcher: TeamEventDispatcher,
        sessionPromptRenderer: ((TeamView, TeamMember) -> String?)? = nil,
        automaticDeliveryOwner: (@Sendable (
            _ teamID: String,
            _ worktree: String,
            _ runtime: TeamHookRuntime,
            _ paneSessionName: String?
        ) -> Bool)? = nil,
        agentRecords: @escaping @Sendable () -> [TeamPresenceRecord] = { [] },
        agentReachability: @escaping @Sendable (TeamPresenceRecord) -> Bool = { _ in false }
    ) {
        self.inbox = inbox
        self.dispatcher = dispatcher
        self.sessionPromptRenderer = sessionPromptRenderer
        self.automaticDeliveryOwner = automaticDeliveryOwner
        self.agentRecords = agentRecords
        self.agentReachability = agentReachability
    }

    @discardableResult
    public func send(
        callerWorktree: String,
        callerAgentID: String? = nil,
        recipient: String,
        text: String,
        priority: TeamInboxPriority,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> TeamInboxDelivery {
        // Validate recipient exists up front so the CLI error message
        // stays helpful (the dispatcher would silently no-op on an unknown
        // recipient, returning nil — not a useful error for `team msg`).
        let context = try teamContext(callerWorktree: callerWorktree, repos: repos, teamsEnabled: teamsEnabled)
        let addressed = splitAgentAddress(recipient, in: context.team)
        guard let recipientMember = context.team.memberNamed(addressed.member) else {
            let available = context.team.members
                .map(\.name)
                .filter { $0 != context.sender.name }
            throw TeamInboxRequestError.recipientNotFound(name: recipient, available: available)
        }
        // AGENT-6.17: an explicit `#agent-id` suffix binds the row to that
        // exact reachable agent and fails closed here when it is gone. A
        // plain worktree address must stay unpinned: delivery re-resolves
        // the default agent per attempt (AGENT-6.3), so stamping the
        // send-time default would wedge the whole worktree queue behind a
        // row no live agent may consume once that agent exits.
        let selectedAgent: TeamAgentDescriptor?
        if let explicitAgentID = addressed.agentID {
            do {
                selectedAgent = try TeamAgentDirectory(
                    records: agentRecords().filter { $0.teamID == teamID(context.team) },
                    isReachable: agentReachability
                ).resolve(
                    worktreePath: recipientMember.worktreePath,
                    explicitAgentID: explicitAgentID
                )
            } catch TeamAgentDirectoryError.explicitAgentNotFound(let id) {
                throw TeamInboxRequestError.agentNotFound(id)
            } catch TeamAgentDirectoryError.explicitAgentUnavailable(let id) {
                throw TeamInboxRequestError.agentUnavailable(id)
            }
        } else {
            selectedAgent = nil
        }
        let senderIdentity = callerAgentID.flatMap(TeamAgentIdentity.init(rawValue:))

        // Validated above (teamContext + memberNamed), so the dispatcher
        // cannot return nil here. Force-unwrap rather than re-throwing a
        // misleading `notInTeam`.
        let message = try dispatcher.dispatchTeamMessage(
            fromWorktree: callerWorktree,
            to: addressed.member,
            text: text,
            priority: priority,
            repos: repos,
            teamsEnabled: teamsEnabled,
            senderRuntime: senderIdentity?.runtime,
            senderAgentID: senderIdentity?.rawValue,
            recipientRuntime: selectedAgent?.runtime,
            recipientAgentID: selectedAgent?.id.rawValue
        )!
        return TeamInboxDelivery(recipient: recipientMember, message: message)
    }

    @discardableResult
    public func broadcast(
        callerWorktree: String,
        callerAgentID: String? = nil,
        text: String,
        priority: TeamInboxPriority,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> [TeamInboxDelivery] {
        let context = try teamContext(callerWorktree: callerWorktree, repos: repos, teamsEnabled: teamsEnabled)
        let recipients = context.team.members.filter { $0.worktreePath != context.sender.worktreePath }
        let senderIdentity = callerAgentID.flatMap(TeamAgentIdentity.init(rawValue:))
        let messages = try dispatcher.dispatchTeamBroadcast(
            fromWorktree: callerWorktree,
            text: text,
            priority: priority,
            repos: repos,
            teamsEnabled: teamsEnabled,
            senderRuntime: senderIdentity?.runtime,
            senderAgentID: senderIdentity?.rawValue
        )
        // The dispatcher iterates `team.members.filter { $0.worktreePath != sender }` —
        // same order this method computes. Pair them up so the returned
        // `TeamInboxDelivery` carries the matching `TeamMember`.
        return zip(recipients, messages).map { TeamInboxDelivery(recipient: $0.0, message: $0.1) }
    }

    public func advanceRead(
        callerWorktree: String,
        throughID: String,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws {
        let context = try teamContext(
            callerWorktree: callerWorktree,
            repos: repos,
            teamsEnabled: teamsEnabled
        )
        try inbox.advanceRead(
            teamID: teamID(context.team),
            recipientWorktree: context.sender.worktreePath,
            throughID: throughID
        )
    }

    public func members(
        callerWorktree: String?,
        worktree: String?,
        repo: String?,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> (teamName: String, members: [TeamListMember]) {
        let context = try scopedTeamContext(
            callerWorktree: callerWorktree,
            worktree: worktree,
            repo: repo,
            repos: repos,
            teamsEnabled: teamsEnabled
        )
        // One presence scan and one directory for the whole team; the
        // production `agentRecords` closure walks and decodes every presence
        // file on disk, so calling it per member would be O(members * files).
        let directory = TeamAgentDirectory(
            records: agentRecords().filter { $0.teamID == teamID(context.team) },
            isReachable: agentReachability
        )
        let agentsByWorktree = Dictionary(
            grouping: directory.agents,
            by: \.worktreePath
        )
        let members = context.team.members.map { member in
            TeamListMember(
                name: member.name,
                branch: member.branch,
                worktreePath: member.worktreePath,
                isMainWorktree: member.isMainWorktree,
                isRunning: member.isRunning,
                agents: (agentsByWorktree[member.worktreePath] ?? []).map { agent in
                    TeamListAgent(
                        id: agent.id.rawValue,
                        address: agent.address(worktreeAddress: member.worktreePath),
                        runtime: agent.runtime,
                        displayName: agent.displayName,
                        isReachable: agent.isReachable,
                        paneSessionName: agent.paneSessionName
                    )
                }
            )
        }
        return (context.team.repoDisplayName, members)
    }

    public func diagnosticPage(
        callerWorktree: String?,
        worktree: String?,
        repo: String?,
        member: String?,
        unread: Bool,
        all: Bool,
        beforeID: String?,
        afterID: String? = nil,
        snapshotThroughID: String? = nil,
        forwardPagination: Bool? = nil,
        limit: Int?,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> TeamInboxDiagnosticPage {
        // `beforeID` is naturally absent on the first page, so `limit` is the
        // pagination capability signal. Refuse older clients explicitly: a
        // full response can overflow their socket reader, while returning one
        // page would silently omit the remainder.
        guard let limit else {
            throw TeamInboxRequestError.paginationRequired
        }
        let context = try scopedTeamContext(
            callerWorktree: callerWorktree,
            worktree: worktree,
            repo: repo,
            repos: repos,
            teamsEnabled: teamsEnabled
        )
        let resolvedTeamID = teamID(context.team)
        let pageLimit = min(
            max(limit, 1),
            TeamInboxDiagnosticPage.maximumLimit
        )

        if unread {
            guard forwardPagination == true else {
                throw TeamInboxRequestError.paginationRequired
            }
            let messages: [TeamInboxMessage]
            let effectiveSnapshotID: String?
            if let afterID {
                let allMessages = try inbox.messages(teamID: resolvedTeamID)
                guard let snapshotThroughID else {
                    throw TeamInboxRequestError.paginationRequired
                }
                guard let afterIndex = allMessages.lastIndex(where: { $0.id == afterID }) else {
                    throw TeamInboxRequestError.paginationCursorNotFound(afterID)
                }
                guard let snapshotIndex = allMessages.lastIndex(where: { $0.id == snapshotThroughID }) else {
                    throw TeamInboxRequestError.paginationCursorNotFound(snapshotThroughID)
                }
                guard afterIndex < snapshotIndex else {
                    throw TeamInboxRequestError.paginationCursorNotFound(afterID)
                }
                messages = allMessages[(afterIndex + 1)...snapshotIndex].filter {
                    $0.to.worktree == context.viewer.worktreePath
                }
                effectiveSnapshotID = snapshotThroughID
            } else {
                let snapshot = try inbox.worktreeUnreadSnapshot(
                    teamID: resolvedTeamID,
                    recipientWorktree: context.viewer.worktreePath
                )
                messages = snapshot.messages
                effectiveSnapshotID = snapshot.throughID
            }

            let filteredMessages: [TeamInboxMessage]
            if let member {
                filteredMessages = messages.filter {
                    $0.to.member == member || $0.from.member == member
                }
            } else {
                filteredMessages = messages
            }
            let candidates = filteredMessages[...]
            let pageMessages = try TeamInboxDiagnosticPaginator.oldestPage(
                from: candidates,
                countLimit: pageLimit,
                encodedByteLimit: TeamInboxDiagnosticPage.maximumEncodedBytes
            )
            let nextAfterID = candidates.count > pageMessages.count
                ? pageMessages.last?.id
                : nil
            return TeamInboxDiagnosticPage(
                messages: pageMessages,
                nextAfterID: nextAfterID,
                snapshotThroughID: effectiveSnapshotID
            )
        }

        var messages = try inbox.messages(teamID: resolvedTeamID)
        if let member {
            messages = messages.filter { $0.to.member == member || $0.from.member == member }
        } else if !all {
            messages = messages.filter { $0.to.worktree == context.viewer.worktreePath }
        }
        let candidates: ArraySlice<TeamInboxMessage>
        if let beforeID {
            if let index = messages.lastIndex(where: { $0.id == beforeID }) {
                candidates = messages[..<index]
            } else {
                throw TeamInboxRequestError.paginationCursorNotFound(beforeID)
            }
        } else {
            candidates = messages[...]
        }
        let pageMessages = try TeamInboxDiagnosticPaginator.newestPage(
            from: candidates,
            countLimit: pageLimit,
            encodedByteLimit: TeamInboxDiagnosticPage.maximumEncodedBytes
        )
        let nextBeforeID = candidates.count > pageMessages.count
            ? pageMessages.first?.id
            : nil
        return TeamInboxDiagnosticPage(
            messages: pageMessages,
            nextBeforeID: nextBeforeID
        )
    }

    public func hook(
        callerWorktree: String,
        runtime: TeamHookRuntime,
        event: TeamHookEvent,
        sessionID: String?,
        paneSessionName: String?,
        repos: [RepoEntry],
        teamsEnabled: Bool,
        instructions: String = "",
        agentID: String? = nil,
        skillManaged: Bool = false
    ) throws -> String {
        let context = try teamContext(callerWorktree: callerWorktree, repos: repos, teamsEnabled: teamsEnabled)
        let sessionID = sessionID ?? "\(runtime.rawValue):\(context.sender.name):\(context.sender.worktreePath)"
        let agentID = agentID
            ?? TeamAgentIdentity(runtime: runtime, nativeSessionID: sessionID).rawValue
        let teamID = teamID(context.team)

        switch event {
        case .sessionStart:
            let ownsAutomaticDelivery = canConsumeAutomaticInbox(
                teamID: teamID,
                worktree: context.sender.worktreePath,
                runtime: runtime,
                paneSessionName: paneSessionName
            )
            let cursor = ownsAutomaticDelivery ? try cursorForHook(
                teamID: teamID,
                sessionID: sessionID,
                worktree: context.sender.worktreePath,
                runtime: runtime
            ) : nil
            let readPosition: String?
            let pending: [TeamInboxMessage]
            if let cursor {
                let unread = try inbox.hookUnreadMessages(
                    teamID: teamID,
                    recipientWorktree: context.sender.worktreePath,
                    sessionLastSeenID: cursor.lastSeenID
                )
                readPosition = unread.readPosition
                pending = hookDeliverablePrefix(
                    unread.messages,
                    teamID: teamID,
                    worktree: context.sender.worktreePath,
                    runtime: runtime,
                    agentID: agentID
                )
            } else {
                readPosition = nil
                pending = []
            }
            let text: String
            if skillManaged {
                text = ""
            } else if let sessionPromptRenderer {
                // A configured session template owns the complete prompt.
                // Empty or invalid templates intentionally suppress it.
                text = sessionPromptRenderer(context.team, context.sender) ?? ""
            } else {
                text = TeamInstructionsRenderer.render(
                    team: context.team,
                    viewer: context.sender
                )
            }
            let output = try TeamHookRenderer.sessionStart(
                runtime: runtime,
                teamContext: text,
                instructions: instructions,
                messages: pending
            )
            if cursor != nil {
                try advanceCursorAcrossDeliveredPrefix(
                    delivered: pending,
                    allUnread: pending,
                    teamID: teamID,
                    sessionID: sessionID,
                    worktree: context.sender.worktreePath,
                    runtime: runtime,
                    after: readPosition
                )
            }
            return output
        case .postToolUse:
            guard runtime != .codex else {
                return try TeamHookRenderer.postToolUse(runtime: runtime, messages: [])
            }
            guard canConsumeAutomaticInbox(
                teamID: teamID,
                worktree: context.sender.worktreePath,
                runtime: runtime,
                paneSessionName: paneSessionName
            ) else {
                return try TeamHookRenderer.postToolUse(runtime: runtime, messages: [])
            }
            let cursor = try cursorForHook(
                teamID: teamID,
                sessionID: sessionID,
                worktree: context.sender.worktreePath,
                runtime: runtime
            )
            let unread = try inbox.hookUnreadMessages(
                teamID: teamID,
                recipientWorktree: context.sender.worktreePath,
                sessionLastSeenID: cursor.lastSeenID
            )
            let deliverableUnread = hookDeliverablePrefix(
                unread.messages,
                teamID: teamID,
                worktree: context.sender.worktreePath,
                runtime: runtime,
                agentID: agentID
            )
            let messages = deliverableUnread.filter { $0.priority == .urgent }
            let output = try TeamHookRenderer.postToolUse(
                runtime: runtime,
                messages: messages
            )
            try advanceCursorAcrossDeliveredPrefix(
                delivered: messages,
                allUnread: deliverableUnread,
                teamID: teamID,
                sessionID: sessionID,
                worktree: context.sender.worktreePath,
                runtime: runtime,
                after: unread.readPosition
            )
            return output
        case .stop:
            // Stop renderer is a no-op (`{}`) for both runtimes —
            // neither runtime's Stop schema accepts
            // `hookSpecificOutput.additionalContext`, so we can't
            // deliver content here. Skip the cursor advance too, since
            // advancing it would silently mark messages "delivered"
            // and bury them past the next real delivery path. The
            // Claude side picks them up via the asyncRewake watcher;
            // Codex hook delivery is intentionally disabled.
            return try TeamHookRenderer.stop(runtime: runtime, messages: [])
        }
    }

    private struct Context {
        let team: TeamView
        let sender: TeamMember
    }

    private struct ScopedContext {
        let team: TeamView
        let viewer: TeamMember
    }

    private func canConsumeAutomaticInbox(
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) -> Bool {
        automaticDeliveryOwner?(teamID, worktree, runtime, paneSessionName) ?? true
    }

    private func teamContext(
        callerWorktree: String,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> Context {
        guard teamsEnabled else { throw TeamInboxRequestError.teamModeDisabled }
        guard let caller = worktree(path: callerWorktree, in: repos) else {
            throw TeamInboxRequestError.callerNotTracked
        }
        guard let team = TeamView.team(for: caller, in: repos, teamsEnabled: true) else {
            throw TeamInboxRequestError.notInTeam
        }
        guard let sender = team.members.first(where: { $0.worktreePath == callerWorktree }) else {
            throw TeamInboxRequestError.senderNotInTeam
        }
        return Context(team: team, sender: sender)
    }

    private func scopedTeamContext(
        callerWorktree: String?,
        worktree: String?,
        repo repoPath: String?,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> ScopedContext {
        guard teamsEnabled else { throw TeamInboxRequestError.teamModeDisabled }
        guard let viewer = resolveScopedWorktree(callerWorktree: callerWorktree, worktree: worktree, repo: repoPath, repos: repos) else {
            throw TeamInboxRequestError.callerNotTracked
        }
        guard let team = TeamView.team(for: viewer, in: repos, teamsEnabled: true) else {
            throw TeamInboxRequestError.notInTeam
        }
        guard let member = team.members.first(where: { $0.worktreePath == viewer.path }) else {
            throw TeamInboxRequestError.senderNotInTeam
        }
        return ScopedContext(team: team, viewer: member)
    }

    private func resolveScopedWorktree(
        callerWorktree: String?,
        worktree worktreeScope: String?,
        repo repoPath: String?,
        repos: [RepoEntry]
    ) -> WorktreeEntry? {
        let scopedRepos = repoPath.map { path in repos.filter { $0.path == path } } ?? repos
        if let worktreeScope {
            if let byPath = worktree(path: worktreeScope, in: scopedRepos) {
                return byPath
            }
            for repo in scopedRepos {
                for worktree in repo.worktrees {
                    if WorktreeNameSanitizer.sanitize(worktree.branch) == worktreeScope {
                        return worktree
                    }
                }
            }
            return nil
        }
        if let callerWorktree {
            return worktree(path: callerWorktree, in: scopedRepos)
        }
        return scopedRepos.first?.worktrees.first
    }

    private func worktree(path: String, in repos: [RepoEntry]) -> WorktreeEntry? {
        for repo in repos {
            if let worktree = repo.worktrees.first(where: { $0.path == path }) {
                return worktree
            }
        }
        return nil
    }

    private func cursorForHook(
        teamID: String,
        sessionID: String,
        worktree: String,
        runtime: TeamHookRuntime
    ) throws -> TeamInboxCursor {
        if let existing = try inbox.cursor(teamID: teamID, sessionID: sessionID) {
            return existing
        }
        let lastSeen = try inbox.worktreeWatermark(teamID: teamID, worktree: worktree)?
            .lastDeliveredToAnySessionID
        let cursor = TeamInboxCursor(
            sessionID: sessionID,
            worktree: worktree,
            runtime: runtime.rawValue,
            lastSeenID: lastSeen
        )
        try inbox.writeCursor(cursor, teamID: teamID)
        return cursor
    }

    private func advanceCursorAcrossDeliveredPrefix(
        delivered: [TeamInboxMessage],
        allUnread: [TeamInboxMessage],
        teamID: String,
        sessionID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        after lastSeenID: String?
    ) throws {
        guard !delivered.isEmpty else { return }
        let deliveredIDs = Set(delivered.map(\.id))
        var advanceTo = lastSeenID
        for message in allUnread {
            guard deliveredIDs.contains(message.id) else { break }
            advanceTo = message.id
        }
        guard advanceTo != lastSeenID else { return }
        // TEAM-11.7: commit the (fallible, lock-guarded) watermark before
        // the cursor, mirroring `claimNextUnreadMessage`. If the watermark
        // advance times out under lock contention, the cursor must not
        // already point past messages this hook never delivered — that
        // would skip them permanently. A watermark that lands without its
        // cursor mirror at worst redelivers (at-least-once), never loses.
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: worktree,
                lastDeliveredToAnySessionID: advanceTo
            ),
            teamID: teamID
        )
        try? inbox.writeCursor(
            TeamInboxCursor(
                sessionID: sessionID,
                worktree: worktree,
                runtime: runtime.rawValue,
                lastSeenID: advanceTo
            ),
            teamID: teamID
        )
    }

    private func endpoint(_ member: TeamMember, runtime: String?) -> TeamInboxEndpoint {
        TeamInboxEndpoint(member: member.name, worktree: member.worktreePath, runtime: runtime)
    }

    private func splitAgentAddress(
        _ recipient: String,
        in team: TeamView
    ) -> (member: String, agentID: String?) {
        let literal = splitLiteralAgentAddress(recipient, in: team)
        if team.memberNamed(literal.member) != nil {
            return literal
        }
        let unescaped = Self.unescapeXMLAttribute(recipient)
        guard unescaped != recipient else { return literal }
        return splitLiteralAgentAddress(unescaped, in: team)
    }

    private func hookDeliverablePrefix(
        _ messages: [TeamInboxMessage],
        teamID: String,
        worktree: String,
        runtime: TeamHookRuntime,
        agentID: String
    ) -> [TeamInboxMessage] {
        let directory = TeamAgentDirectory(
            records: agentRecords().filter { $0.teamID == teamID },
            isReachable: agentReachability
        )
        let defaultAgent = try? directory.resolve(
            worktreePath: worktree,
            explicitAgentID: nil
        )
        let acceptsUntargeted = defaultAgent == nil
            || (defaultAgent?.runtime == runtime && defaultAgent?.id.rawValue == agentID)
        return TeamInbox.runtimeDeliverablePrefix(
            messages,
            runtime: runtime.rawValue,
            agentID: agentID,
            acceptsUntargeted: acceptsUntargeted
        )
    }

    private func splitLiteralAgentAddress(
        _ recipient: String,
        in team: TeamView
    ) -> (member: String, agentID: String?) {
        // Prefer an exact member/path match so existing branch names that
        // contain `#` remain valid. Canonical suffixes are recognized only
        // after a known absolute worktree path or convenience display name
        // plus a literal separator. Paths sort first naturally in most cases,
        // but explicit length ordering also handles names nested in paths.
        if team.memberNamed(recipient) != nil {
            return (recipient, nil)
        }
        let candidates = team.members.flatMap { member in
            [
                (address: member.worktreePath, member: member.worktreePath),
                (address: member.name, member: member.name),
            ]
        }.sorted { lhs, rhs in
            lhs.address.count > rhs.address.count
        }
        for candidate in candidates {
            let prefix = candidate.address + "#"
            guard recipient.hasPrefix(prefix) else { continue }
            let id = String(recipient.dropFirst(prefix.count))
            return (candidate.member, id.isEmpty ? nil : id)
        }
        return (recipient, nil)
    }

    private static func unescapeXMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func teamID(_ team: TeamView) -> String {
        team.repoPath
    }
}
