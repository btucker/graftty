import Foundation
import GrafttyProtocol

public enum FlowStateContextBuilder {
    public static func build(
        appState: AppState,
        summaries: [String: FlowWorktreeSummary],
        notes: [String: FlowWorktreeNote],
        snoozes: [String: FlowSnooze],
        signals: FlowExternalSignals = .empty,
        now: Date
    ) -> FlowContextEnvelope {
        let selectedRepoPath = appState.selectedWorktreePath.flatMap { selectedPath in
            appState.repo(forWorktreePath: selectedPath)?.path
        }

        let snapshots = appState.repos.flatMap { repo in
            repo.worktrees.map { worktree in
                snapshot(
                    repo: repo,
                    worktree: worktree,
                    selectedWorktreePath: appState.selectedWorktreePath,
                    selectedRepoPath: selectedRepoPath,
                    summaries: summaries,
                    notes: notes,
                    snoozes: snoozes,
                    signals: signals
                )
            }
        }

        return FlowContextEnvelope(generatedAt: now, worktrees: snapshots)
    }

    private static func snapshot(
        repo: RepoEntry,
        worktree: WorktreeEntry,
        selectedWorktreePath: String?,
        selectedRepoPath: String?,
        summaries: [String: FlowWorktreeSummary],
        notes: [String: FlowWorktreeNote],
        snoozes: [String: FlowSnooze],
        signals: FlowExternalSignals
    ) -> FlowWorktreeSnapshot {
        let worktreeKey = FlowWorktreeIdentity.key(repoPath: repo.path, worktreePath: worktree.path)
        let sanitizedBranch = WorktreeNameSanitizer.sanitize(worktree.branch)
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: repo.displayName,
            repoPath: repo.path,
            worktreePath: worktree.path,
            branch: worktree.branch
        )
        let displayRef = "\(repo.displayName):\(sanitizedBranch)"
        let selected = selectedWorktreePath == worktree.path
        let sameRepoAsSelected = selectedRepoPath == repo.path
        let resumptionCostHint = resumptionCost(selected: selected, sameRepoAsSelected: sameRepoAsSelected)
        let attention = snapshotAttention(for: worktree)
        let summary = summaries[worktreeRef] ?? summaries[worktreeKey]
        let note = notes[worktreeRef] ?? notes[worktreeKey]
        let snooze = snoozes[worktreeRef] ?? snoozes[worktreeKey]
        let agentPresence = signals.agentPresence(worktreeRef: worktreeRef, worktreeKey: worktreeKey)
        let git = signals.git(worktreeRef: worktreeRef, worktreeKey: worktreeKey)
        let pr = signals.pr(worktreeRef: worktreeRef, worktreeKey: worktreeKey)
        let activity = signals.activity(worktreeRef: worktreeRef, worktreeKey: worktreeKey)
        let scoring = scoringHints(
            selected: selected,
            sameRepoAsSelected: sameRepoAsSelected,
            summary: summary,
            attention: attention,
            agentPresence: agentPresence,
            pr: pr,
            git: git
        )

        return FlowWorktreeSnapshot(
            repoPath: repo.path,
            repoName: repo.displayName,
            worktreeName: sanitizedBranch,
            worktreePath: worktree.path,
            worktreeBranch: worktree.branch,
            worktreeState: worktree.state,
            worktreeKey: worktreeKey,
            worktreeRef: worktreeRef,
            displayRef: displayRef,
            selected: selected,
            focusedPaneSlotID: worktree.focusedPaneSlotID,
            focusedPaneSessionID: worktree.focusedPaneSlotID.flatMap { worktree.paneSessions[$0] },
            lastUserActivityAt: activity?.lastUserActivityAt,
            lastAgentActivityAt: activity?.lastAgentActivityAt,
            attention: attention,
            agentPresence: agentPresence,
            pr: pr,
            git: git,
            summary: summary,
            summaryText: summary?.summary,
            nextAction: summary?.nextAction,
            needsHuman: summary?.needsHuman,
            note: note,
            lastFlowMessageAt: activity?.lastFlowMessageAt,
            snooze: snooze,
            topicLabels: topicLabels(repoName: repo.displayName, sanitizedBranch: sanitizedBranch),
            clarity: summary != nil || attention != nil ? .clear : .unclear,
            resumptionCostHint: resumptionCostHint,
            scoring: scoring
        )
    }

    private static func snapshotAttention(for worktree: WorktreeEntry) -> FlowSnapshotAttention? {
        if let attention = worktree.attention {
            return FlowSnapshotAttention(text: attention.text, timestamp: attention.timestamp, source: attention.source)
        }

        let paneAttention = worktree.paneAttention.sorted { lhs, rhs in
            if lhs.value.timestamp == rhs.value.timestamp {
                return lhs.key.id.uuidString < rhs.key.id.uuidString
            }
            return lhs.value.timestamp > rhs.value.timestamp
        }

        guard let first = paneAttention.first else { return nil }
        return FlowSnapshotAttention(
            text: first.value.text,
            timestamp: first.value.timestamp,
            source: first.value.source,
            paneSlotID: first.key
        )
    }

    private static func resumptionCost(selected: Bool, sameRepoAsSelected: Bool) -> FlowResumptionCostHint {
        if selected {
            return .low
        }
        if sameRepoAsSelected {
            return .medium
        }
        return .high
    }

    private static func scoringHints(
        selected: Bool,
        sameRepoAsSelected: Bool,
        summary: FlowWorktreeSummary?,
        attention: FlowSnapshotAttention?,
        agentPresence: FlowAgentPresenceSnapshot?,
        pr: FlowPRSnapshot?,
        git: FlowGitSnapshot?
    ) -> FlowScoringHints {
        FlowScoringHints(
            flowAffinity: flowAffinity(selected: selected, sameRepoAsSelected: sameRepoAsSelected),
            unlockValue: unlockValue(summary: summary, attention: attention, agentPresence: agentPresence, pr: pr),
            riskUrgency: riskUrgency(pr: pr, git: git),
            completionMomentum: completionMomentum(summary: summary, agentPresence: agentPresence),
            interruptPenalty: interruptPenalty(selected: selected, sameRepoAsSelected: sameRepoAsSelected)
        )
    }

    private static func flowAffinity(selected: Bool, sameRepoAsSelected: Bool) -> FlowAffinityHint {
        if selected {
            return .high
        }
        if sameRepoAsSelected {
            return .medium
        }
        return .low
    }

    private static func unlockValue(
        summary: FlowWorktreeSummary?,
        attention: FlowSnapshotAttention?,
        agentPresence: FlowAgentPresenceSnapshot?,
        pr: FlowPRSnapshot?
    ) -> FlowUnlockValueHint {
        if summary?.needsHuman == true || agentPresence?.waiting == true || attention?.source == .agentStop {
            return .high
        }
        if prHasRisk(pr) {
            return .medium
        }
        return .low
    }

    private static func riskUrgency(pr: FlowPRSnapshot?, git: FlowGitSnapshot?) -> FlowRiskUrgencyHint {
        if pr?.urgency == .critical {
            return .critical
        }
        if prConclusionIsFailure(pr?.ciConclusion) || prMergeStateIsDirty(pr?.mergeState) {
            return .high
        }
        if pr != nil || gitHasChanges(git) {
            return .medium
        }
        return .low
    }

    private static func completionMomentum(
        summary: FlowWorktreeSummary?,
        agentPresence: FlowAgentPresenceSnapshot?
    ) -> FlowCompletionMomentumHint {
        if summary?.nextAction?.isEmpty == false && summary?.needsHuman == false {
            return .high
        }
        if summary != nil || agentPresence?.busy == true {
            return .medium
        }
        return .low
    }

    private static func interruptPenalty(selected: Bool, sameRepoAsSelected: Bool) -> FlowInterruptPenaltyHint {
        if selected {
            return .low
        }
        if sameRepoAsSelected {
            return .medium
        }
        return .high
    }

    private static func topicLabels(repoName: String, sanitizedBranch: String) -> [FlowTopicLabel] {
        var seen: Set<String> = []
        var labels: [FlowTopicLabel] = []

        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            labels.append(FlowTopicLabel(trimmed))
        }

        append(repoName)
        for component in sanitizedBranch.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" }) {
            append(String(component))
        }
        return labels
    }

    private static func prHasRisk(_ pr: FlowPRSnapshot?) -> Bool {
        guard let pr else { return false }
        return prConclusionIsFailure(pr.ciConclusion) || prMergeStateIsDirty(pr.mergeState) || pr.state != nil
    }

    private static func prConclusionIsFailure(_ conclusion: String?) -> Bool {
        guard let conclusion else { return false }
        let normalized = conclusion.lowercased()
        return normalized == "failure" || normalized == "failed" || normalized == "error" || normalized == "cancelled"
    }

    private static func prMergeStateIsDirty(_ mergeState: String?) -> Bool {
        guard let mergeState else { return false }
        let normalized = mergeState.lowercased()
        return normalized == "dirty" || normalized == "blocked" || normalized == "behind"
    }

    private static func gitHasChanges(_ git: FlowGitSnapshot?) -> Bool {
        guard let git else { return false }
        return (git.dirtyCount ?? 0) > 0 || (git.ahead ?? 0) > 0 || (git.behind ?? 0) > 0
    }
}
