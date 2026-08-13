import Foundation
import GrafttyProtocol

/// The slice of `TeamInbox` the roster notifier appends through; a seam so
/// tests can inject per-recipient append failures.
protocol TeamRosterAnnouncementAppending {
    @discardableResult
    func appendMessage(
        teamID: String,
        teamName: String,
        repoPath: String,
        from: TeamInboxEndpoint,
        to: TeamInboxEndpoint,
        priority: TeamInboxPriority,
        kind: String,
        body: String,
        agentPrompt: String?,
        source: String?
    ) throws -> TeamInboxMessage
}

extension TeamInbox: TeamRosterAnnouncementAppending {}

/// Tracks the reachable top-level provider sessions seen during this app
/// process. Existing sessions seed the snapshot at startup so an app relaunch
/// does not manufacture join events for agents that were already running.
public actor TeamAgentRosterNotifier {
    private struct Scope: Hashable, Sendable {
        let teamID: String
        let worktree: String
    }

    private let inbox: any TeamRosterAnnouncementAppending
    private let isReachable: @Sendable (TeamPresenceRecord) -> Bool
    private var observedAgentIDs: [Scope: Set<String>]

    public init(
        inbox: TeamInbox,
        initialRecords: [TeamPresenceRecord],
        isReachable: @escaping @Sendable (TeamPresenceRecord) -> Bool
    ) {
        self.init(
            appendingTo: inbox,
            initialRecords: initialRecords,
            isReachable: isReachable
        )
    }

    init(
        appendingTo inbox: any TeamRosterAnnouncementAppending,
        initialRecords: [TeamPresenceRecord],
        isReachable: @escaping @Sendable (TeamPresenceRecord) -> Bool
    ) {
        self.inbox = inbox
        self.isReachable = isReachable
        self.observedAgentIDs = Self.snapshot(
            records: initialRecords,
            isReachable: isReachable
        ).mapValues { Set($0.map(\.id.rawValue)) }
    }

    /// Reconciles all worktree rosters and emits one exact-addressed message
    /// to every current agent in a worktree when that worktree gains agents.
    /// Announcements are at-most-once: if an append fails partway through a
    /// worktree's recipients, that worktree's snapshot still advances (rows
    /// before the failure are already committed, so a retry would duplicate
    /// them into live agent sessions) and the remaining worktrees are still
    /// processed in the same pass. A missed announcement is acceptable —
    /// roster changes are advisory and the roster is queryable on demand.
    public func reconcile(
        records: [TeamPresenceRecord],
        repos: [RepoEntry]
    ) throws {
        let current = Self.snapshot(records: records, isReachable: isReachable)

        for (scope, agents) in current {
            let currentIDs = Set(agents.map(\.id.rawValue))
            let joinedIDs = currentIDs.subtracting(observedAgentIDs[scope] ?? [])
            guard !joinedIDs.isEmpty else { continue }
            guard let context = Self.context(for: scope, repos: repos) else {
                // The worktree is not resolvable yet (repos still loading);
                // leave the scope unobserved so the join is announced on a
                // later reconciliation instead of being swallowed.
                continue
            }

            let joined = agents.filter { joinedIDs.contains($0.id.rawValue) }
            let body = Self.messageBody(
                memberName: context.memberName,
                worktreeAddress: scope.worktree,
                joined: joined,
                roster: agents
            )
            do {
                for recipient in agents {
                    try inbox.appendMessage(
                        teamID: scope.teamID,
                        teamName: context.teamName,
                        repoPath: context.repoPath,
                        from: .system(repoPath: context.repoPath),
                        to: TeamInboxEndpoint(
                            member: context.memberName,
                            worktree: scope.worktree,
                            runtime: recipient.runtime.rawValue,
                            agentID: recipient.id.rawValue
                        ),
                        priority: .normal,
                        kind: "team_agent_joined",
                        body: body,
                        agentPrompt: nil,
                        source: nil
                    )
                }
            } catch {
                // At-most-once: rows appended before the failure are already
                // committed, so retrying this scope next tick would duplicate
                // announcements into live agent sessions. Advance the
                // snapshot below, accept the missed announcement for the
                // failed recipient, and keep reconciling the other scopes.
            }
            // Ever-seen accumulation: a scope's set only grows, so a
            // transient reachability dip (or a failed presence read that
            // surfaces as an empty snapshot) can never re-announce agents
            // that were already introduced during this app process.
            observedAgentIDs[scope, default: []].formUnion(currentIDs)
        }
    }

    private struct Context: Sendable {
        let teamName: String
        let repoPath: String
        let memberName: String
    }

    private static func context(for scope: Scope, repos: [RepoEntry]) -> Context? {
        guard let repo = repos.first(where: { repo in
            repo.path == scope.teamID
                || repo.worktrees.contains(where: { $0.path == scope.worktree })
        }), let worktree = repo.worktrees.first(where: { $0.path == scope.worktree }) else {
            return nil
        }
        return Context(
            teamName: repo.displayName,
            repoPath: repo.path,
            memberName: WorktreeNameSanitizer.sanitize(worktree.branch)
        )
    }

    private static func snapshot(
        records: [TeamPresenceRecord],
        isReachable: (TeamPresenceRecord) -> Bool
    ) -> [Scope: [TeamAgentDescriptor]] {
        let directory = TeamAgentDirectory(records: records, isReachable: isReachable)
        var grouped: [Scope: [String: TeamAgentDescriptor]] = [:]
        for agent in directory.agents where agent.isReachable {
            let scope = Scope(teamID: agent.teamID, worktree: agent.worktreePath)
            grouped[scope, default: [:]][agent.id.rawValue] = agent
        }
        return grouped.mapValues { agentsByID in
            agentsByID.values.sorted(by: TeamAgentDirectory.isOrderedBefore)
        }
    }

    private static func messageBody(
        memberName: String,
        worktreeAddress: String,
        joined: [TeamAgentDescriptor],
        roster: [TeamAgentDescriptor]
    ) -> String {
        let joinedText = joined.map { describe($0, worktreeAddress: worktreeAddress) }.joined(separator: ", ")
        let rosterText = roster.map { describe($0, worktreeAddress: worktreeAddress) }.joined(separator: ", ")
        return """
        Agent roster changed in worktree \(memberName).
        Joined: \(joinedText)
        Current top-level agents: \(rosterText)
        Refresh with `graftty team list --json`. If another agent is the right owner, forward the work with `graftty team send --stdin <exact-address>`.
        """
    }

    private static func describe(
        _ agent: TeamAgentDescriptor,
        worktreeAddress: String
    ) -> String {
        let display = agent.displayName.map { " (\($0))" } ?? ""
        return agent.address(worktreeAddress: worktreeAddress)
            + " [\(agent.runtime.rawValue)]\(display)"
    }
}
