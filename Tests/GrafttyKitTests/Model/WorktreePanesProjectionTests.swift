import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("@spec IPAD-1.23: When a host publishes or renders a worktree row, the application shall project it through the one shared WorktreePanes projection, sending a pane layout only for a running worktree unless the Mac sidebar asks to keep a stopped worktree's saved layout, and dropping divergence stats for a worktree without an on-disk checkout.")
struct WorktreePanesProjectionTests {
    private let slot = PaneSlotID()
    private let session = PaneSessionID()

    private func entry(_ state: WorktreeState) -> (WorktreeEntry, RepoEntry) {
        var worktree = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: state,
                                     splitTree: SplitTree(root: .leaf(slot)))
        worktree.paneSessions = [slot: session]
        worktree.paneAttention = [slot: Attention(text: "ready", timestamp: Date(timeIntervalSinceReferenceDate: 7), source: .agentStop)]
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])
        return (worktree, repo)
    }

    private let stats = WorktreeWireStats(ahead: 1, behind: 2, hasUncommittedChanges: false, baseRef: "origin/main")

    @Test func runningRowCarriesLayoutLeafFromEntry() {
        let (worktree, repo) = entry(.running)
        let name = ZmxLauncher.sessionName(for: session)
        let row = WorktreePanes(entry: worktree, repo: repo, inputs: WorktreeRowInputs(
            origin: nil, projectID: "p", displayName: "feature", paneTitles: [slot: "vim"], liveness: [name: .busy]))
        #expect(row.layout == .leaf(sessionName: name, title: "vim", attentionText: "ready", isBusy: true,
                                    attentionSource: .agentStop, attentionTimestamp: Date(timeIntervalSinceReferenceDate: 7)))
        #expect(row.state == .running)
        #expect(row.repositoryID == "/repo")
        #expect(row.isMainCheckout == false)
        #expect(row.sidebar?.id == "p:\(worktree.id.uuidString)")
    }

    @Test func stoppedRowDropsLayoutUnlessRequested() {
        let (worktree, repo) = entry(.closed)
        let published = WorktreePanes(entry: worktree, repo: repo, inputs: .init(origin: nil, projectID: "p", displayName: ""))
        let sidebar = WorktreePanes(entry: worktree, repo: repo, inputs: .init(origin: nil, projectID: "p", displayName: "",
                                                                                  includeLayoutWhenStopped: true))
        #expect(published.layout == nil)
        #expect(sidebar.layout?.leaves.map(\.sessionName) == [ZmxLauncher.sessionName(for: session)])
    }

    @Test(arguments: [WorktreeState.stale, .creating, .deleting])
    func statsDroppedWithoutOnDiskWorktree(_ state: WorktreeState) {
        let (worktree, repo) = entry(state)
        let row = WorktreePanes(entry: worktree, repo: repo, inputs: .init(origin: nil, projectID: "p", displayName: "", stats: stats))
        #expect(row.stats == nil)
        #expect(row.state == WorktreeWireState(state))
    }

    @Test(arguments: [WorktreeState.closed, .running])
    func statsKeptWithOnDiskWorktree(_ state: WorktreeState) {
        let (worktree, repo) = entry(state)
        let row = WorktreePanes(entry: worktree, repo: repo, inputs: .init(origin: nil, projectID: "p", displayName: "", stats: stats))
        #expect(row.stats == stats)
    }

    @Test func untitledAndSessionlessLeavesPublishEmptyStrings() {
        let other = PaneSlotID()
        let node = SplitTree.Node.split(.init(direction: .vertical, ratio: 0.25, left: .leaf(slot), right: .leaf(other)))
        let layout = node.wireLayout(sessions: [slot: session], titles: [:], attention: [:], liveness: [:])
        #expect(layout == .split(direction: .vertical, ratio: 0.25,
            left: .leaf(sessionName: ZmxLauncher.sessionName(for: session), title: "", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "", title: "", attentionText: nil, isBusy: false, attentionSource: nil)))
    }

    @Test func wireStateBridgeIsTotal() {
        for state in [WorktreeState.closed, .running, .stale, .creating, .deleting] {
            #expect(state.wireState.rawValue == state.rawValue)
            #expect(state.hasOnDiskWorktree == state.wireState.hasOnDiskWorktree)
            #expect(state.isInFlight == state.wireState.isInFlight)
        }
    }
}
