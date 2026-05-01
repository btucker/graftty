import Foundation
import GrafttyProtocol

public enum TeamInboxRequestError: Error, Equatable, CustomStringConvertible {
    case teamModeDisabled
    case callerNotTracked
    case notInTeam
    case senderNotInTeam
    case recipientNotFound(name: String, available: [String])

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
        }
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

    public init(
        inbox: TeamInbox,
        dispatcher: TeamEventDispatcher,
        sessionPromptRenderer: ((TeamView, TeamMember) -> String?)? = nil
    ) {
        self.inbox = inbox
        self.dispatcher = dispatcher
        self.sessionPromptRenderer = sessionPromptRenderer
    }

    @discardableResult
    public func send(
        callerWorktree: String,
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
        guard let recipientMember = context.team.memberNamed(recipient) else {
            let available = context.team.members
                .map(\.name)
                .filter { $0 != context.sender.name }
            throw TeamInboxRequestError.recipientNotFound(name: recipient, available: available)
        }

        // Validated above (teamContext + memberNamed), so the dispatcher
        // cannot return nil here. Force-unwrap rather than re-throwing a
        // misleading `notInTeam`.
        let message = try dispatcher.dispatchTeamMessage(
            fromWorktree: callerWorktree,
            to: recipient,
            text: text,
            priority: priority,
            repos: repos,
            teamsEnabled: teamsEnabled
        )!
        return TeamInboxDelivery(recipient: recipientMember, message: message)
    }

    @discardableResult
    public func broadcast(
        callerWorktree: String,
        text: String,
        priority: TeamInboxPriority,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> [TeamInboxDelivery] {
        let context = try teamContext(callerWorktree: callerWorktree, repos: repos, teamsEnabled: teamsEnabled)
        let recipients = context.team.members.filter { $0.worktreePath != context.sender.worktreePath }
        let messages = try dispatcher.dispatchTeamBroadcast(
            fromWorktree: callerWorktree,
            text: text,
            priority: priority,
            repos: repos,
            teamsEnabled: teamsEnabled
        )
        // The dispatcher iterates `team.members.filter { $0.worktreePath != sender }` —
        // same order this method computes. Pair them up so the returned
        // `TeamInboxDelivery` carries the matching `TeamMember`.
        return zip(recipients, messages).map { TeamInboxDelivery(recipient: $0.0, message: $0.1) }
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
        let members = context.team.members.map { member in
            TeamListMember(
                name: member.name,
                branch: member.branch,
                worktreePath: member.worktreePath,
                role: member.role.rawValue,
                isRunning: member.isRunning
            )
        }
        return (context.team.repoDisplayName, members)
    }

    public func diagnosticMessages(
        callerWorktree: String?,
        worktree: String?,
        repo: String?,
        member: String?,
        unread: Bool,
        all: Bool,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> [TeamInboxMessage] {
        let context = try scopedTeamContext(
            callerWorktree: callerWorktree,
            worktree: worktree,
            repo: repo,
            repos: repos,
            teamsEnabled: teamsEnabled
        )
        var messages = try inbox.messages(teamID: teamID(context.team))
        if let member {
            messages = messages.filter { $0.to.member == member || $0.from.member == member }
        } else if unread || !all {
            messages = messages.filter { $0.to.worktree == context.viewer.worktreePath }
        }
        return messages
    }

    public func hook(
        callerWorktree: String,
        runtime: TeamHookRuntime,
        event: TeamHookEvent,
        sessionID: String?,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> String {
        let context = try teamContext(callerWorktree: callerWorktree, repos: repos, teamsEnabled: teamsEnabled)
        let sessionID = sessionID ?? "\(runtime.rawValue):\(context.sender.name):\(context.sender.worktreePath)"
        let teamID = teamID(context.team)
        let cursor = try cursorForHook(
            teamID: teamID,
            sessionID: sessionID,
            worktree: context.sender.worktreePath,
            runtime: runtime
        )

        switch event {
        case .sessionStart:
            var text = TeamInstructionsRenderer.render(team: context.team, viewer: context.sender)
            if let renderedPrompt = sessionPromptRenderer?(context.team, context.sender) {
                text += "\n\n\(renderedPrompt)"
            }
            return try TeamHookRenderer.sessionStart(runtime: runtime, teamContext: text)
        case .postToolUse:
            let allUnread = try inbox.unreadMessages(
                teamID: teamID,
                recipientWorktree: context.sender.worktreePath,
                after: cursor.lastSeenID
            )
            let messages = allUnread.filter { $0.priority == .urgent }
            try advanceCursorAcrossDeliveredPrefix(
                delivered: messages,
                allUnread: allUnread,
                teamID: teamID,
                sessionID: sessionID,
                worktree: context.sender.worktreePath,
                runtime: runtime,
                after: cursor.lastSeenID
            )
            return try TeamHookRenderer.postToolUse(runtime: runtime, messages: messages)
        case .stop:
            let messages = try inbox.unreadMessages(
                teamID: teamID,
                recipientWorktree: context.sender.worktreePath,
                after: cursor.lastSeenID
            )
            try advanceCursorAcrossDeliveredPrefix(
                delivered: messages,
                allUnread: messages,
                teamID: teamID,
                sessionID: sessionID,
                worktree: context.sender.worktreePath,
                runtime: runtime,
                after: cursor.lastSeenID
            )
            return try TeamHookRenderer.stop(runtime: runtime, messages: messages)
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
        try inbox.writeCursor(
            TeamInboxCursor(
                sessionID: sessionID,
                worktree: worktree,
                runtime: runtime.rawValue,
                lastSeenID: advanceTo
            ),
            teamID: teamID
        )
        try inbox.writeWorktreeWatermark(
            TeamInboxWorktreeWatermark(
                worktree: worktree,
                lastDeliveredToAnySessionID: advanceTo
            ),
            teamID: teamID
        )
    }

    private func endpoint(_ member: TeamMember, runtime: String?) -> TeamInboxEndpoint {
        TeamInboxEndpoint(member: member.name, worktree: member.worktreePath, runtime: runtime)
    }

    private func teamID(_ team: TeamView) -> String {
        team.repoPath
    }
}
