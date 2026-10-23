import Foundation
import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("AttentionAutoClear")
struct AttentionAutoClearTests {
    private static let path = "/repo/feature"

    @MainActor
    private final class StateBox {
        var state: AppState
        init(_ state: AppState) { self.state = state }
        var binding: Binding<AppState> {
            Binding(get: { self.state }, set: { self.state = $0 })
        }
        var worktree: WorktreeEntry { state.repos[0].worktrees[0] }
    }

    private static func box(
        attention: Attention?,
        paneAttention: [PaneSlotID: Attention] = [:]
    ) -> StateBox {
        var worktree = WorktreeEntry(path: path, branch: "feature", state: .running)
        worktree.attention = attention
        worktree.paneAttention = paneAttention
        return StateBox(AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])]))
    }

    /// Lets the zero-delay timer fire before the test inspects state.
    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }

    @Test("clears the worktree attention whose timestamp matches the stamp")
    func clearsMatchingWorktreeAttention() async {
        let stamp = Date()
        let box = Self.box(attention: Attention(text: "done", timestamp: stamp))

        AttentionAutoClear.schedule(after: 0, appState: box.binding, worktreePath: Self.path, stamp: stamp)
        await Self.drainMainQueue()

        #expect(box.worktree.attention == nil)
    }

    @Test("leaves a newer worktree attention in place")
    func keepsNewerWorktreeAttention() async {
        let stamp = Date()
        let box = Self.box(attention: Attention(text: "newer", timestamp: stamp.addingTimeInterval(1)))

        AttentionAutoClear.schedule(after: 0, appState: box.binding, worktreePath: Self.path, stamp: stamp)
        await Self.drainMainQueue()

        #expect(box.worktree.attention?.text == "newer")
    }

    /// A legacy or hand-edited `state.json` can carry a `clearAfter` past
    /// the STATE-2.9 cap; resuming it must not overflow `Duration` and trap.
    @Test("an out-of-range resumed delay neither traps nor clears early")
    func outOfRangeDelayIsClamped() async {
        let stamp = Date()
        let box = Self.box(attention: Attention(text: "done", timestamp: stamp, clearAfter: 1e30))

        AttentionAutoClear.schedule(after: 1e30, appState: box.binding, worktreePath: Self.path, stamp: stamp)
        await Self.drainMainQueue()

        #expect(box.worktree.attention?.text == "done")
    }

    @Test("clears only the targeted pane attention")
    func clearsOnlyTargetedPane() async {
        let stamp = Date()
        let target = PaneSlotID()
        let sibling = PaneSlotID()
        let box = Self.box(
            attention: Attention(text: "worktree", timestamp: stamp),
            paneAttention: [
                target: Attention(text: "target", timestamp: stamp),
                sibling: Attention(text: "sibling", timestamp: stamp),
            ]
        )

        AttentionAutoClear.schedule(
            after: 0,
            appState: box.binding,
            worktreePath: Self.path,
            pane: target,
            stamp: stamp
        )
        await Self.drainMainQueue()

        #expect(box.worktree.paneAttention[target] == nil)
        #expect(box.worktree.paneAttention[sibling]?.text == "sibling")
        #expect(box.worktree.attention?.text == "worktree")
    }
}
