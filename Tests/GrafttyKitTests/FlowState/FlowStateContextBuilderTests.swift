import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("FlowStateContextBuilder")
struct FlowStateContextBuilderTests {
    @Test("@spec FLOW-2.1: `graftty flow context` shall expose each tracked worktree as a FlowWorktreeSnapshot with repo identity, worktree identity, selected/focused state, attention state, stored summary fields, scoring hints, and external git/agent signals when available.")
    func snapshotsIncludeWorktreeSignalsAndSummaries() throws {
        var wt = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        let focusedPane = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        let focusedSession = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)
        wt.focusedPaneSlotID = focusedPane
        wt.paneSessions[focusedPane] = focusedSession
        wt.setAttention(
            Attention(text: "Codex needs input", timestamp: Date(timeIntervalSince1970: 10), source: .agentStop),
            pane: nil
        )
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [wt])
        let appState = AppState(repos: [repo], selectedWorktreePath: wt.path)
        let worktreeRef = FlowWorktreeIdentity.ref(
            repoDisplayName: "repo",
            repoPath: "/repo",
            worktreePath: wt.path,
            branch: wt.branch
        )
        let summary = FlowWorktreeSummary(
            worktreeRef: worktreeRef,
            updatedAt: Date(timeIntervalSince1970: 20),
            summary: "Agent is blocked on API choice.",
            nextAction: "Answer the API question.",
            needsHuman: true
        )
        let note = FlowWorktreeNote(
            worktreeRef: worktreeRef,
            updatedAt: Date(timeIntervalSince1970: 21),
            body: "Prefer the smaller API surface."
        )
        let snooze = FlowSnooze(
            worktreeRef: worktreeRef,
            updatedAt: Date(timeIntervalSince1970: 22),
            until: .nextFocusBreak,
            reason: "Wait until current reply is handled."
        )

        let context = FlowStateContextBuilder.build(
            appState: appState,
            summaries: [worktreeRef: summary],
            notes: [worktreeRef: note],
            snoozes: [worktreeRef: snooze],
            signals: FlowExternalSignals(
                agentPresenceByWorktreeRef: [
                    worktreeRef: FlowAgentPresenceSnapshot(runtime: "codex", present: true, busy: false, waiting: true)
                ],
                gitByWorktreeRef: [
                    worktreeRef: FlowGitSnapshot(dirtyCount: 2, ahead: 1, behind: 0)
                ],
                prByWorktreeRef: [
                    worktreeRef: FlowPRSnapshot(number: 42, state: "open", ciConclusion: "failure", mergeState: "dirty")
                ],
                activityByWorktreeRef: [
                    worktreeRef: FlowActivitySnapshot(
                        lastUserActivityAt: Date(timeIntervalSince1970: 12),
                        lastAgentActivityAt: Date(timeIntervalSince1970: 18),
                        lastFlowMessageAt: Date(timeIntervalSince1970: 19)
                    )
                ]
            ),
            now: Date(timeIntervalSince1970: 30)
        )

        let snapshot = try #require(context.worktrees.first)
        #expect(snapshot.repoName == "repo")
        #expect(snapshot.displayRef == "repo:feature")
        #expect(snapshot.worktreeRef.contains("repo#"))
        #expect(snapshot.selected == true)
        #expect(snapshot.focusedPaneSlotID == focusedPane)
        #expect(snapshot.focusedPaneSessionID == focusedSession)
        #expect(snapshot.attention?.text == "Codex needs input")
        #expect(snapshot.summary?.needsHuman == true)
        #expect(snapshot.note?.body == "Prefer the smaller API surface.")
        #expect(snapshot.snooze?.until == .nextFocusBreak)
        #expect(snapshot.agentPresence?.waiting == true)
        #expect(snapshot.git?.dirtyCount == 2)
        #expect(snapshot.pr?.ciConclusion == "failure")
        #expect(snapshot.lastFlowMessageAt == Date(timeIntervalSince1970: 19))
        #expect(snapshot.scoring.unlockValue == .high)
        #expect(snapshot.resumptionCostHint == .low)
    }

    @Test("@spec FLOW-2.2: When a worktree has no summary and ambiguous observable state, Flow State context shall mark the snapshot as unclear instead of inventing a next action.")
    func unclearWhenNoSummaryOrAttention() throws {
        let wt = WorktreeEntry(path: "/repo/.worktrees/old", branch: "old", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [wt])
        let context = FlowStateContextBuilder.build(
            appState: AppState(repos: [repo]),
            summaries: [:],
            notes: [:],
            snoozes: [:],
            signals: .empty,
            now: Date(timeIntervalSince1970: 30)
        )
        #expect(context.worktrees.first?.clarity == .unclear)
        #expect(context.worktrees.first?.nextAction == nil)
    }

    @Test("@spec FLOW-2.3: Flow State shall use collision-resistant worktree identities so two repositories with the same display name and branch cannot share summaries, snoozes, notes, or status-request cooldowns.")
    func worktreeIdentityDoesNotCollideAcrossSameNamedRepos() throws {
        let first = WorktreeEntry(path: "/one/app/.worktrees/feature", branch: "feature", state: .running)
        let second = WorktreeEntry(path: "/two/app/.worktrees/feature", branch: "feature", state: .running)
        let appState = AppState(repos: [
            RepoEntry(path: "/one/app", displayName: "app", worktrees: [first]),
            RepoEntry(path: "/two/app", displayName: "app", worktrees: [second])
        ])
        let firstRef = FlowWorktreeIdentity.ref(
            repoDisplayName: "app",
            repoPath: "/one/app",
            worktreePath: first.path,
            branch: first.branch
        )
        let firstKey = FlowWorktreeIdentity.key(repoPath: "/one/app", worktreePath: first.path)
        let summary = FlowWorktreeSummary(
            worktreeRef: firstRef,
            updatedAt: Date(timeIntervalSince1970: 20),
            summary: "Only the first repo has this summary.",
            nextAction: "Keep identities distinct.",
            needsHuman: false
        )

        let context = FlowStateContextBuilder.build(
            appState: appState,
            summaries: [firstKey: summary],
            notes: [:],
            snoozes: [:],
            signals: .empty,
            now: Date(timeIntervalSince1970: 30)
        )

        #expect(Set(context.worktrees.map(\.worktreeKey)).count == 2)
        #expect(Set(context.worktrees.map(\.worktreeRef)).count == 2)
        #expect(context.worktrees.allSatisfy { $0.displayRef == "app:feature" })
        #expect(context.worktrees.first { $0.worktreePath == first.path }?.summary?.summary == "Only the first repo has this summary.")
        #expect(context.worktrees.first { $0.worktreePath == second.path }?.summary == nil)
    }

    @Test("@spec FLOW-2.4: Flow State scoring shall preserve the current human context by ranking selected or same-repo low-reload work above unrelated failing CI unless the unrelated work is critical or explicitly higher payoff.")
    func scoringDoesNotDefaultToUrgencyFirst() throws {
        let current = WorktreeEntry(path: "/repo/.worktrees/current", branch: "current", state: .running)
        let nearby = WorktreeEntry(path: "/repo/.worktrees/review", branch: "review", state: .running)
        let remote = WorktreeEntry(path: "/other/.worktrees/ci", branch: "ci", state: .running)
        let appState = AppState(
            repos: [
                RepoEntry(path: "/repo", displayName: "repo", worktrees: [current, nearby]),
                RepoEntry(path: "/other", displayName: "other", worktrees: [remote])
            ],
            selectedWorktreePath: current.path
        )
        let currentRef = FlowWorktreeIdentity.ref(
            repoDisplayName: "repo",
            repoPath: "/repo",
            worktreePath: current.path,
            branch: current.branch
        )
        let remoteRef = FlowWorktreeIdentity.ref(
            repoDisplayName: "other",
            repoPath: "/other",
            worktreePath: remote.path,
            branch: remote.branch
        )
        let context = FlowStateContextBuilder.build(
            appState: appState,
            summaries: [
                currentRef: FlowWorktreeSummary(
                    worktreeRef: currentRef,
                    updatedAt: Date(timeIntervalSince1970: 20),
                    summary: "Active work",
                    nextAction: "Finish test",
                    needsHuman: false
                )
            ],
            notes: [:],
            snoozes: [:],
            signals: FlowExternalSignals(
                prByWorktreeRef: [
                    remoteRef: FlowPRSnapshot(number: 9, state: "open", ciConclusion: "failure", mergeState: nil)
                ]
            ),
            now: Date(timeIntervalSince1970: 30)
        )

        let selected = try #require(context.worktrees.first { $0.worktreePath == current.path })
        let sameRepo = try #require(context.worktrees.first { $0.worktreePath == nearby.path })
        let unrelated = try #require(context.worktrees.first { $0.worktreePath == remote.path })
        #expect(selected.scoring.flowAffinity.rawRank > unrelated.scoring.flowAffinity.rawRank)
        #expect(sameRepo.scoring.flowAffinity.rawRank > unrelated.scoring.flowAffinity.rawRank)
        #expect(selected.resumptionCostHint == .low)
        #expect(sameRepo.resumptionCostHint == .medium)
        #expect(unrelated.resumptionCostHint == .high)
    }
}
