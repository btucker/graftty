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
    func publishContextSnapshots(handoff: AttentionFileHandoff = AttentionFileHandoff()) {
        for worktree in repos.flatMap(\.worktrees) {
            try? publishContextSnapshot(worktree: worktree.path, handoff: handoff)
        }
    }

    func publishContextSnapshot(worktree path: String, handoff: AttentionFileHandoff = AttentionFileHandoff()) throws {
        guard let worktree = worktree(forPath: path) else { return }
        try handoff.publishContext(worktree.brief, worktree: path, emoji: worktree.emoji, iconDescription: worktree.drawing?.description)
    }

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

    /// Like the brief, only a recap newer than the brief may change the
    /// drawing, so a late or dropped report cannot revert it (AGENT-3.34).
    private mutating func adoptDrawing(from recap: AttentionRecap, callerPath: String, reportedAt: Date) {
        guard recap.icon != nil, let index = indices(forWorktreePath: callerPath) else { return }
        let worktree = repos[index.repo].worktrees[index.worktree]
        if recap.contextUpdate != nil {
            guard reportedAt > (worktree.drawing?.adoptedAt ?? .distantPast) else { return }
        } else {
            guard worktree.isNewerThanBrief(reportedAt) else { return }
        }
        SidebarHostNavigation.adoptReportedDrawing(recap, worktreePath: callerPath,
            projectHue: ProjectHueRegistry.shared.hue(for: repos[index.repo].id), in: &repos)
        if repos[index.repo].worktrees[index.worktree].drawing != worktree.drawing {
            repos[index.repo].worktrees[index.worktree].drawing?.adoptedAt = reportedAt
        }
    }

    /// Publishes retained context without marking the agent stopped.
    mutating func recordAgentRecap(_ recap: AttentionRecap, callerPath: String, reportedAt: Date, callerAgentID: String? = nil) {
        guard let index = indices(forWorktreePath: callerPath) else { return }
        let owns = ownsContext(callerAgentID: callerAgentID, path: callerPath)
        if owns { SidebarHostNavigation.adoptReportedEmoji(recap, worktreePath: callerPath, in: &repos) }
        if mayAdoptDrawing(owns: owns, path: callerPath) { adoptDrawing(from: recap, callerPath: callerPath, reportedAt: reportedAt) }
        guard owns else { return }
        repos[index.repo].worktrees[index.worktree].recordAgentRecap(recap.withoutDrawing, at: reportedAt)
    }

    /// @spec AGENT-3.52
    /// While a linked worktree has no drawing, the application shall adopt the first valid drawing any agent in that worktree reports, while only the context owner may replace an existing drawing or change the rest of the retained context.
    private func mayAdoptDrawing(owns: Bool, path: String) -> Bool {
        owns || worktree(forPath: path)?.drawing == nil
    }

    private func ownsContext(callerAgentID: String?, path: String) -> Bool {
        guard let worktree = worktree(forPath: path) else { return false }
        guard let callerAgentID, let agent = worktree.agents.first(where: { $0.id == callerAgentID || $0.nativeAgentID == callerAgentID }) else {
            return !worktree.agents.contains { worktree.isPrimaryAgent($0) }
        }
        return worktree.isPrimaryAgent(agent)
    }

    func hasConsumedAgentReport(callerPath: String, runtime: TeamHookRuntime, callerAgentID: String?,
                                sessionID: String?, reportedAt: Date, receiptID: UUID? = nil) -> Bool {
        guard let key = AgentHookAttentionIdentity.key(runtime: runtime, sessionID: sessionID, callerAgentID: callerAgentID),
              let consumed = worktree(forPath: callerPath)?.consumedAgentReports[key] else { return false }
        return consumed.contains(receiptID: receiptID, reportedAt: reportedAt)
    }

    /// Records a provider's stopped turn on the sidebar. Stops older than
    /// the same session's last progress, older than the recorded stop, or
    /// identical to it are dropped. Returns a notification if the turn requests input.
    mutating func recordStoppedTurn(callerPath: String, runtime: TeamHookRuntime, callerAgentID: String?,
                                    sessionID: String?, paneSessionName: String?, recap: AttentionRecap?,
                                    stoppedAt: Date, recapReportedAt: Date? = nil, turnID: String? = nil, paneTitle: (PaneSlotID, WorktreeEntry) -> String?) -> AgentStopNotificationContent? {
        let worktree = worktree(forPath: callerPath)
        let owner = AgentHookAttentionIdentity.key(runtime: runtime, sessionID: sessionID, callerAgentID: callerAgentID)
        let consumed = owner.flatMap { worktree?.consumedAgentReports[$0] }
        let isConsumed = recapReportedAt.map { date in
            consumed?.contains(receiptID: recap?.contextUpdate?.receiptID, reportedAt: date) ?? false
        } ?? false
        // A recovered duplicate is a no-op. A distinct provider turn still
        // completes, but cannot reuse the old recap or its pending question.
        if isConsumed, turnID == nil || consumed?.turnID == turnID { return nil }
        let effectiveRecap = isConsumed ? nil : recap?.withoutDrawing
        let paneSlot = paneSessionName.flatMap { worktree?.paneSlot(forSessionName: $0) }
        let stop = SidebarAgentStop(
            agentName: runtime.displayName,
            stoppedAt: stoppedAt,
            recap: effectiveRecap,
            paneTitle: paneSlot.flatMap { slot in worktree.flatMap { paneTitle(slot, $0) } },
            paneSlotID: paneSlot?.id.uuidString,
            providerSessionKey: AgentHookAttentionIdentity.key(
                runtime: runtime, sessionID: sessionID, callerAgentID: callerAgentID
            )
        )
        if stop.notice == nil, let key = stop.providerSessionKey, let progressedAt = worktree?.agentProgressTimes[key],
           progressedAt > stop.timestamp { return nil }
        if let previous = worktree?.lastAgentStop {
            if stop.notice == nil, previous.timestamp > stop.timestamp { return nil }
            if previous.timestamp == stop.timestamp, previous.providerSessionKey == stop.providerSessionKey { return nil }
        }
        if worktree?.unreadAgentNotices.contains(where: { $0.occurrence == stop.occurrence }) == true { return nil }
        let owns = ownsContext(callerAgentID: callerAgentID, path: callerPath)
        if owns { SidebarHostNavigation.adoptReportedEmoji(effectiveRecap, worktreePath: callerPath, in: &repos) }
        if !isConsumed, let recap, mayAdoptDrawing(owns: owns, path: callerPath) {
            adoptDrawing(from: recap, callerPath: callerPath, reportedAt: recapReportedAt ?? stoppedAt)
        }
        guard let index = indices(forWorktreePath: callerPath) else { return nil }
        if let effectiveRecap {
            recordAgentRecap(effectiveRecap, callerPath: callerPath, reportedAt: recapReportedAt ?? stoppedAt, callerAgentID: callerAgentID)
        }
        repos[index.repo].worktrees[index.worktree].recordAgentStop(stop, recapReportedAt: recapReportedAt, updatesContext: false)
        if let recapReportedAt, let key = stop.providerSessionKey {
            let latestReport = max(consumed?.reportedAt ?? -.infinity, recapReportedAt.timeIntervalSinceReferenceDate)
            var receipt = WorktreeEntry.ConsumedAgentReport(reportedAt: latestReport,
                turnID: recapReportedAt.timeIntervalSinceReferenceDate >= (consumed?.reportedAt ?? -.infinity) ? turnID : consumed?.turnID)
            receipt.receiptIDs = consumed?.receiptIDs
            if let id = recap?.contextUpdate?.receiptID, !(receipt.receiptIDs ?? []).contains(id) {
                receipt.receiptIDs = Array(((receipt.receiptIDs ?? []) + [id]).suffix(128))
            }
            repos[index.repo].worktrees[index.worktree].consumedAgentReports[key] = receipt
            if repos[index.repo].worktrees[index.worktree].consumedAgentReports.count > 20,
               let oldest = repos[index.repo].worktrees[index.worktree].consumedAgentReports.min(by: { $0.value.reportedAt < $1.value.reportedAt })?.key {
                repos[index.repo].worktrees[index.worktree].consumedAgentReports.removeValue(forKey: oldest)
            }
        }
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

private extension AttentionRecap {
    /// @spec AGENT-3.35
    /// Stored stops, briefs and broadcasts never carry agent SVG; the drawing
    /// lives only on the worktree that adopted it.
    var withoutDrawing: AttentionRecap {
        var stripped = contextUpdate.map(AttentionRecap.init(update:)) ?? self
        stripped.icon = nil
        stripped.iconDescription = nil
        stripped.contextUpdate?.icon = nil
        stripped.contextUpdate?.iconDescription = nil
        return stripped
    }
}
