import Foundation
import GrafttyProtocol

/// A `notify` auto-clear the caller must schedule. The clear only removes
/// attention still carrying `timestamp`, so a newer ping or an explicit
/// clear that lands first survives the timer.
public struct AttentionAutoClear: Sendable, Equatable {
    public let worktreePath: String
    public let pane: PaneSlotID?
    public let timestamp: Date
    public let delay: TimeInterval
}

/// Attention mutations behind the control socket and the provider file
/// handoff, shared by the Mac app and the headless host.
public extension AppState {
    /// `graftty notify`. Invalid text and untracked paths are ignored
    /// (ATTN-1.7 defense in depth). A pane session that resolves within the
    /// worktree scopes the attention to that pane (AGENT-4.1/4.2);
    /// otherwise it falls back to the worktree.
    mutating func applyUserNotify(path: String, text: String, clearAfter: TimeInterval?,
                                  paneSessionName: String?, now: Date = Date()) -> AttentionAutoClear? {
        guard Attention.isValidText(text), let index = indices(forWorktreePath: path) else { return nil }
        // STATE-2.8/2.9: the server is the single source of truth for what schedules.
        let delay = Attention.effectiveClearAfter(clearAfter)
        let attention = Attention(text: text, timestamp: now, clearAfter: delay, source: .userNotify)
        if let paneSessionName,
           let slot = repos[index.repo].worktrees[index.worktree].paneSlot(forSessionName: paneSessionName) {
            if let delay {
                // An auto-clearing pane badge belongs to the worktree whose
                // layout holds the pane; a session mapping left without a
                // live leaf writes nothing.
                guard let owner = indices(forPaneSlot: slot) else { return nil }
                repos[owner.repo].worktrees[owner.worktree].setAttention(attention, pane: slot)
                return AttentionAutoClear(worktreePath: repos[owner.repo].worktrees[owner.worktree].path,
                                          pane: slot, timestamp: now, delay: delay)
            }
            repos[index.repo].worktrees[index.worktree].setAttention(attention, pane: slot)
            return nil
        }
        repos[index.repo].worktrees[index.worktree].setAttention(attention, pane: nil)
        return delay.map { AttentionAutoClear(worktreePath: path, pane: nil, timestamp: now, delay: $0) }
    }

    mutating func applyAutoClear(_ clear: AttentionAutoClear) {
        guard let index = indices(forWorktreePath: clear.worktreePath) else { return }
        if let pane = clear.pane {
            repos[index.repo].worktrees[index.worktree].clearPaneAttentionIfTimestamp(clear.timestamp, for: pane)
        } else {
            repos[index.repo].worktrees[index.worktree].clearAttentionIfTimestamp(clear.timestamp)
        }
    }

    /// `graftty clear`: a resolvable pane session clears only that pane;
    /// otherwise the worktree-scoped attention clears.
    mutating func applyUserClear(path: String, paneSessionName: String?) {
        guard let index = indices(forWorktreePath: path) else { return }
        if let paneSessionName,
           let slot = repos[index.repo].worktrees[index.worktree].paneSlot(forSessionName: paneSessionName) {
            repos[index.repo].worktrees[index.worktree].paneAttention[slot] = nil
            return
        }
        repos[index.repo].worktrees[index.worktree].attention = nil
    }

    /// Records a provider's stopped turn on the sidebar. Stops older than
    /// the same session's last progress, older than the recorded stop, or
    /// identical to it are dropped. Returns the notification to post.
    mutating func recordStoppedTurn(callerPath: String, runtime: TeamHookRuntime, callerAgentID: String?,
                                    sessionID: String?, paneSessionName: String?, recap: AttentionRecap?,
                                    stoppedAt: Date, paneTitle: (PaneSlotID, WorktreeEntry) -> String?) -> AgentStopNotificationContent? {
        let worktree = worktree(forPath: callerPath)
        let paneSlot = paneSessionName.flatMap { worktree?.paneSlot(forSessionName: $0) }
        let stop = SidebarAgentStop(
            agentName: runtime.displayName,
            stoppedAt: stoppedAt,
            recap: recap,
            paneTitle: paneSlot.flatMap { slot in worktree.flatMap { paneTitle(slot, $0) } },
            paneSlotID: paneSlot?.id.uuidString,
            providerSessionKey: AgentHookAttentionIdentity.key(
                runtime: runtime, sessionID: sessionID, callerAgentID: callerAgentID
            )
        )
        if let key = stop.providerSessionKey, let progressedAt = worktree?.agentProgressTimes[key],
           progressedAt > stop.timestamp { return nil }
        if let previous = worktree?.lastAgentStop {
            if previous.timestamp > stop.timestamp { return nil }
            if previous.timestamp == stop.timestamp, previous.providerSessionKey == stop.providerSessionKey,
               previous.recap == stop.recap { return nil }
        }
        SidebarHostNavigation.adoptReportedEmoji(recap, worktreePath: callerPath, in: &repos)
        guard let index = indices(forWorktreePath: callerPath) else { return nil }
        repos[index.repo].worktrees[index.worktree].recordAgentStop(stop)
        let recorded = repos[index.repo].worktrees[index.worktree]
        return AgentStopNotification.stoppedTurnContent(
            runtime: runtime, worktreeName: WorktreeNameSanitizer.sanitize(recorded.branch),
            worktreePath: callerPath, sessionID: sessionID ?? callerAgentID ?? "",
            paneSessionName: paneSessionName, stop: stop,
            emoji: recorded.effectiveEmoji(in: repos[index.repo]),
            purposeTitle: recorded.brief?.title
        )
    }

    /// Records blocking agent attention (permission, question, failure)
    /// owned by one provider session. Returns the notification to post, or
    /// nil when the session is unidentified or already has attention.
    mutating func recordAgentAttention(callerPath: String, callerAgentID: String?, runtime: TeamHookRuntime,
                                       reason: AgentHookAttentionReason, sessionID: String?,
                                       paneSessionName: String?, now: Date = Date()) -> AgentStopNotificationContent? {
        guard let providerSessionKey = AgentHookAttentionIdentity.key(
            runtime: runtime, sessionID: sessionID, callerAgentID: callerAgentID
        ), let index = indices(forWorktreePath: callerPath) else { return nil }
        let worktree = repos[index.repo].worktrees[index.worktree]
        let worktreeName = WorktreeNameSanitizer.sanitize(worktree.branch)
        let attention = Attention(
            text: AgentStopNotification.attentionText(runtime: runtime, reason: reason),
            timestamp: now, source: .agentStop, providerSessionKey: providerSessionKey
        )
        let pane: PaneSlotID?
        switch AgentStopAttentionTarget.resolve(worktree: worktree, paneSessionName: paneSessionName) {
        case .pane(let slot): pane = slot
        case .worktree: pane = nil
        }
        guard repos[index.repo].worktrees[index.worktree].setAgentStopAttentionIfAbsent(attention, pane: pane) else {
            return nil
        }
        return AgentStopNotification.content(
            runtime: runtime, worktreeName: worktreeName, worktreePath: callerPath,
            sessionID: sessionID ?? "\(runtime.rawValue):\(worktreeName):\(callerPath)",
            paneSessionName: paneSessionName, reason: reason, timestamp: now
        )
    }

    /// Provider progress clears `.agentStop` attention owned by the same session (AGENT-3.4).
    mutating func clearAgentAttention(callerPath: String, callerAgentID: String?, runtime: TeamHookRuntime,
                                      sessionID: String?, progressedAt: Date = Date()) {
        clearAgentStopAttention(
            worktreePath: callerPath,
            providerSessionKey: AgentHookAttentionIdentity.key(
                runtime: runtime, sessionID: sessionID, callerAgentID: callerAgentID
            ),
            progressedAt: progressedAt
        )
    }

    private func indices(forPaneSlot slot: PaneSlotID) -> (repo: Int, worktree: Int)? {
        for (ri, repo) in repos.enumerated() {
            if let wi = repo.worktrees.firstIndex(where: { $0.splitTree.containsLeaf(slot) }) { return (ri, wi) }
        }
        return nil
    }
}
