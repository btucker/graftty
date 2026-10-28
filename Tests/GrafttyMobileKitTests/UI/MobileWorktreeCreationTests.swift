import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("Mobile worktree creation")
struct MobileWorktreeCreationTests {
    private func row(path: String = "opaque-worktree", name: String = "feature", state: WorktreeWireState = .creating, layout: PaneLayoutNode? = nil) -> WorktreePanes {
        WorktreePanes(path: path, displayName: name, repoDisplayName: "Repo", repositoryID: "opaque-repo", displayBranch: "feature", state: state, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: layout)
    }

    private var pane: PaneLayoutNode {
        .leaf(sessionName: "pane", title: "shell", attentionText: nil, isBusy: false, attentionSource: nil)
    }

    @Test("@spec IOS-9.5: When a valid mobile Add Worktree form is submitted, the application shall dismiss the form immediately and display a non-selectable creating row in the target repository while creation runs.")
    func showsPlaceholderUntilRunningPaneArrives() {
        var creation = MobileWorktreeCreation()
        let id = creation.begin(placeholder: row(path: "temporary"), knownPaths: [], generation: 1)
        #expect(creation.rows(in: []).map(\.state) == [.creating])
        // The host may advertise the same row before replying to create.
        #expect(creation.rows(in: [row()]).count == 1)
        // The host can expand the label to distinguish duplicate basenames.
        #expect(creation.rows(in: [row(name: "namespace/feature")]).count == 1)
        creation.complete(id, worktreePath: "opaque-worktree")
        #expect(creation.rows(in: []).count == 1)
        #expect(creation.rows(in: [row(state: .running)]).first?.state == .creating)
        let running = row(state: .running, layout: pane)
        #expect(creation.takeReadySelection(in: [running], generation: 1) == running)
        #expect(creation.rows(in: [running]) == [running])
        #expect(creation.takeReadySelection(in: [running], generation: 1) == nil)
    }

    @Test("@spec IOS-9.3: When mobile worktree creation succeeds, the application shall auto-select the created worktree only after a running pane appears and only if no newer navigation intent has superseded creation.")
    func readinessAndNewerIntentGateSelection() {
        var creation = MobileWorktreeCreation()
        let id = creation.begin(placeholder: row(path: "temporary"), knownPaths: [], generation: 1)
        creation.complete(id, worktreePath: "opaque-worktree")
        #expect(creation.takeReadySelection(in: [row()], generation: 1) == nil)
        #expect(creation.takeReadySelection(in: [row(state: .running)], generation: 1) == nil)
        #expect(creation.takeReadySelection(in: [row(state: .closed, layout: pane)], generation: 1) == nil)
        #expect(creation.takeReadySelection(in: [row(state: .running, layout: pane)], generation: 2) == nil)
        #expect(creation.isEmpty)
    }

    @Test("@spec IOS-9.15: When mobile worktree creation fails, the application shall remove its temporary row and show the error outside the dismissed form.")
    func failureRemovesOnlyItsOwnPlaceholder() {
        var creation = MobileWorktreeCreation()
        let first = creation.begin(placeholder: row(path: "first"), knownPaths: [], generation: 1)
        let failed = creation.begin(placeholder: row(path: "failed"), knownPaths: [], generation: 2)
        creation.fail(failed)
        #expect(creation.rows(in: []).map(\.path) == ["first"])
        creation.fail(first)
        #expect(creation.isEmpty)
    }

    @Test("Pending rows preserve authoritative progress in the list and compact project picker")
    func pendingRowsPreserveHostProgress() {
        var creation = MobileWorktreeCreation()
        let existing = row(path: "existing", state: .running, layout: pane)
        _ = creation.begin(placeholder: row(path: "temporary"), knownPaths: [existing.path], generation: 1)
        var progress = WorktreeCreationProgress()
        progress.output = "waiting for hook lock"
        let hostRow = row().with(creationProgress: progress)
        #expect(creation.rows(in: [existing, hostRow]) == [existing, hostRow])
        #expect(creation.pendingRows(in: [existing, hostRow]) == [hostRow])
        progress.transition(to: .failed, error: "setup failed")
        let failed = row(state: .stale).with(creationProgress: progress)
        #expect(creation.pendingRows(in: [existing, failed]) == [failed])
    }

    @Test("Existing rows and other repositories cannot replace the pending creation")
    func preservesUnrelatedRows() {
        var creation = MobileWorktreeCreation()
        let existing = row(path: "existing", state: .running, layout: pane)
        _ = creation.begin(placeholder: row(path: "temporary"), knownPaths: [existing.path], generation: 1)
        #expect(creation.rows(in: [existing]).count == 2)
        let otherRepo = WorktreePanes(path: "other", displayName: "feature", repoDisplayName: "Repo", repositoryID: "other-repo", displayBranch: "feature", state: .creating, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)
        #expect(creation.rows(in: [otherRepo]).count == 2)
    }
}
