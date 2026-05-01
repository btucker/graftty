import Foundation
import GrafttyProtocol

/// Single producer-side fan-out for every team event. `PRStatusStore`,
/// `TeamMembershipEvents`, and the `graftty team msg`/`team broadcast`
/// CLI handlers all flow through here, writing one `TeamInbox` row per
/// matrix-resolved (or addressed) recipient.
public final class TeamEventDispatcher {
    private let inbox: TeamInbox
    private let preferencesProvider: () -> TeamEventRoutingPreferences
    private let templateProvider: () -> String

    public init(
        inbox: TeamInbox,
        preferencesProvider: @escaping () -> TeamEventRoutingPreferences,
        templateProvider: @escaping () -> String
    ) {
        self.inbox = inbox
        self.preferencesProvider = preferencesProvider
        self.templateProvider = templateProvider
    }

    // MARK: - team_message (TEAM-5.1)

    /// Writes a single `team_message` row addressed to the named recipient.
    /// No-ops (silently) when teams are disabled, the sender's worktree is
    /// not in a team, or the recipient is not a teammate.
    @discardableResult
    public func dispatchTeamMessage(
        fromWorktree senderWorktreePath: String,
        to recipientName: String,
        text: String,
        priority: TeamInboxPriority,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> TeamInboxMessage? {
        guard teamsEnabled else { return nil }
        guard let team = TeamLookup.team(for: senderWorktreePath, in: repos),
              let senderMember = team.members.first(where: { $0.worktreePath == senderWorktreePath }),
              let recipientMember = team.memberNamed(recipientName)
        else { return nil }

        let event = ChannelServerMessage.event(
            type: TeamChannelEvents.EventType.message,
            attrs: ["team": team.repoDisplayName, "from": senderMember.name],
            body: text
        )
        let body = renderBody(
            event: event,
            recipientWorktreePath: recipientMember.worktreePath,
            subjectWorktreePath: senderMember.worktreePath,
            repos: repos
        )

        return try inbox.appendMessage(
            teamID: TeamLookup.id(of: team),
            teamName: team.repoDisplayName,
            repoPath: team.repoPath,
            from: TeamInboxEndpoint(
                member: senderMember.name,
                worktree: senderMember.worktreePath,
                runtime: nil
            ),
            to: TeamInboxEndpoint(
                member: recipientMember.name,
                worktree: recipientMember.worktreePath,
                runtime: nil
            ),
            priority: priority,
            kind: TeamChannelEvents.EventType.message,
            body: body
        )
    }

    // MARK: - team broadcast (TEAM-5.10)

    /// Writes one `team_message` row per recipient (every team member
    /// other than the sender). Each row is rendered through the user's
    /// `teamPrompt` template against the recipient's agent context, so
    /// `{{ agent.branch }}` / `{{ agent.lead }}` resolve per-recipient
    /// like every other event the dispatcher fans out.
    ///
    /// Note: `appendBroadcast` (which shares a `batchID` across rows) is
    /// not used because each row carries a recipient-specific rendered
    /// body. The trade-off is that downstream consumers can't recover
    /// "these all came from one broadcast" without a heuristic — but the
    /// unread-fanout cursor logic doesn't rely on `batchID`, so the loss
    /// is cosmetic.
    @discardableResult
    public func dispatchTeamBroadcast(
        fromWorktree senderWorktreePath: String,
        text: String,
        priority: TeamInboxPriority,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> [TeamInboxMessage] {
        guard teamsEnabled else { return [] }
        guard let team = TeamLookup.team(for: senderWorktreePath, in: repos),
              let senderMember = team.members.first(where: { $0.worktreePath == senderWorktreePath })
        else { return [] }

        let recipients = team.members.filter { $0.worktreePath != senderWorktreePath }

        var messages: [TeamInboxMessage] = []
        for recipient in recipients {
            let event = TeamChannelEvents.teamMessage(
                team: team.repoDisplayName,
                from: senderMember.name,
                text: text
            )
            let body = renderBody(
                event: event,
                recipientWorktreePath: recipient.worktreePath,
                subjectWorktreePath: senderMember.worktreePath,
                repos: repos
            )
            let msg = try inbox.appendMessage(
                teamID: TeamLookup.id(of: team),
                teamName: team.repoDisplayName,
                repoPath: team.repoPath,
                from: TeamInboxEndpoint(
                    member: senderMember.name,
                    worktree: senderMember.worktreePath,
                    runtime: nil
                ),
                to: TeamInboxEndpoint(
                    member: recipient.name,
                    worktree: recipient.worktreePath,
                    runtime: nil
                ),
                priority: priority,
                kind: TeamChannelEvents.EventType.message,
                body: body
            )
            messages.append(msg)
        }
        return messages
    }

    // MARK: - Routable matrix events (TEAM-5.5, TEAM-5.6)

    /// Fans a routable `ChannelServerMessage.event(...)` out to one inbox row
    /// per recipient resolved by `TeamEventRouter`. No-ops for events outside
    /// the matrix (`team_message`, `team_member_*`, etc.) and for subject
    /// worktrees not contained in any tracked repo. For single-worktree repos
    /// `TeamEventRouter` still delivers to the subject worktree iff
    /// `.worktree` is in the matrix row, so we resolve the repo directly
    /// rather than going through `TeamLookup.team(for:)` which requires a
    /// real (>=2 worktree) team.
    public func dispatchRoutableEvent(
        _ event: ChannelServerMessage,
        subjectWorktreePath: String,
        repos: [RepoEntry]
    ) throws {
        guard case let .event(type, attrs, _) = event else { return }
        guard let routable = RoutableEvent(channelEventType: type, attrs: attrs) else { return }
        guard let repo = repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == subjectWorktreePath })
        }) else { return }

        let recipients = TeamEventRouter.recipients(
            event: routable,
            subjectWorktreePath: subjectWorktreePath,
            repos: repos,
            preferences: preferencesProvider()
        )
        guard !recipients.isEmpty else { return }

        for recipientPath in recipients {
            let body = renderBody(
                event: event,
                recipientWorktreePath: recipientPath,
                subjectWorktreePath: subjectWorktreePath,
                repos: repos
            )
            let recipientBranch = repo.worktrees.first(where: { $0.path == recipientPath })?.branch ?? ""
            try inbox.appendMessage(
                teamID: TeamLookup.id(forRepoPath: repo.path),
                teamName: repo.displayName,
                repoPath: repo.path,
                from: .system(repoPath: repo.path),
                to: TeamInboxEndpoint(
                    member: WorktreeNameSanitizer.sanitize(recipientBranch),
                    worktree: recipientPath,
                    runtime: nil
                ),
                priority: .normal,
                kind: type,
                body: body
            )
        }
    }

    // MARK: - Membership events (TEAM-5.7, TEAM-5.8)

    /// Writes one `team_member_joined` row addressed to the team lead.
    /// Same suppression rules as `TeamMembershipEvents.fireJoined`:
    /// - team has fewer than two worktrees
    /// - the joiner isn't found in the repo
    /// - the joiner *is* the lead (nobody else to notify)
    public func dispatchMemberJoined(
        joinerWorktreePath: String,
        repos: [RepoEntry]
    ) throws {
        guard let team = TeamLookup.team(for: joinerWorktreePath, in: repos) else { return }
        guard let joiner = team.members.first(where: { $0.worktreePath == joinerWorktreePath }) else { return }
        guard joiner.role != .lead else { return }

        let event = TeamChannelEvents.memberJoined(
            team: team.repoDisplayName,
            member: joiner.name,
            branch: joiner.branch,
            worktree: joiner.worktreePath
        )
        guard case let .event(type, _, _) = event else { return }

        let lead = team.lead
        let body = renderBody(
            event: event,
            recipientWorktreePath: lead.worktreePath,
            subjectWorktreePath: joiner.worktreePath,
            repos: repos
        )
        try inbox.appendMessage(
            teamID: TeamLookup.id(of: team),
            teamName: team.repoDisplayName,
            repoPath: team.repoPath,
            from: .system(repoPath: team.repoPath),
            to: TeamInboxEndpoint(
                member: lead.name,
                worktree: lead.worktreePath,
                runtime: nil
            ),
            priority: .normal,
            kind: type,
            body: body
        )
    }

    /// Writes one `team_member_left` row addressed to the team lead.
    /// The team may have collapsed to one worktree by the time this is
    /// called (so `TeamLookup.team(for:)` returns nil) — we still emit
    /// the row, deriving the team ID from the repo path. Suppression
    /// rules match `TeamMembershipEvents.fireLeft`:
    /// - the lead is no longer present in the repo
    /// - the leaver was the lead itself
    public func dispatchMemberLeft(
        leaverBranch: String,
        leaverWorktreePath: String,
        reason: TeamChannelEvents.LeaveReason,
        repos: [RepoEntry]
    ) throws {
        // Find the repo by checking which one contains a worktree at the
        // leaver's repo root. The leaver is gone from the repo, so we
        // walk all repos and pick the one whose root path is a prefix of
        // the leaver's path (covers both `path == repo.path` and the
        // typical `<repo>/.worktrees/<name>` layout).
        guard let repo = repos.first(where: { repo in
            leaverWorktreePath == repo.path || leaverWorktreePath.hasPrefix(repo.path + "/")
        }) else { return }
        // Lead must still be present and the leaver must not have been the lead.
        guard repo.worktrees.contains(where: { $0.path == repo.path }) else { return }
        guard leaverWorktreePath != repo.path else { return }

        let leaverName = WorktreeNameSanitizer.sanitize(leaverBranch)
        let event = TeamChannelEvents.memberLeft(
            team: repo.displayName,
            member: leaverName,
            reason: reason
        )
        guard case let .event(type, _, _) = event else { return }

        let body = renderBody(
            event: event,
            recipientWorktreePath: repo.path,
            subjectWorktreePath: leaverWorktreePath,
            repos: repos
        )
        try inbox.appendMessage(
            teamID: TeamLookup.id(forRepoPath: repo.path),
            teamName: repo.displayName,
            repoPath: repo.path,
            from: .system(repoPath: repo.path),
            to: TeamInboxEndpoint(
                member: WorktreeNameSanitizer.sanitize(
                    repo.worktrees.first(where: { $0.path == repo.path })?.branch ?? ""
                ),
                worktree: repo.path,
                runtime: nil
            ),
            priority: .normal,
            kind: type,
            body: body
        )
    }

    // MARK: - Body rendering

    /// Renders the user's `teamPrompt` template against the per-recipient
    /// agent context. When the template is empty the original event body
    /// is returned unchanged, matching the legacy channel-path behavior.
    private func renderBody(
        event: ChannelServerMessage,
        recipientWorktreePath: String,
        subjectWorktreePath: String?,
        repos: [RepoEntry]
    ) -> String {
        guard case let .event(_, _, originalBody) = event else { return "" }
        let template = templateProvider()
        guard !template.isEmpty else { return originalBody }
        let rendered = EventBodyRenderer.body(
            for: event,
            recipientWorktreePath: recipientWorktreePath,
            subjectWorktreePath: subjectWorktreePath,
            repos: repos,
            templateString: template
        )
        if case let .event(_, _, body) = rendered { return body }
        return originalBody
    }
}
