#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyMobileKit

@MainActor
@Suite("iPad actual multi-pane detail")
struct MultiPaneDetailViewTests {
    @Test("""
@spec IPAD-2.1: While a worktree is selected and the iPad layout is regular-width, the detail column shall render device-local tabs, splits, and a terminal drawer over the worktree's complete host session inventory.
""")
    func ipad_2_1_usesCompleteHostInventory() {
        let worktree = makeWorktree(layout: Self.layout)
        let view = makeView(worktree: worktree, focusedPaneId: "top")

        #expect(view.worktree.layout == Self.layout)
        #expect(MultiPaneDetailView.liveSessionNames(in: view.worktree.layout) == [
            "left", "top", "bottom",
        ])
    }

    @Test("""
@spec IPAD-2.4: When `MultiPaneDetailView` renders a `.leaf(sessionName, …)`, the application shall render a `PaneLeafView` that owns its own SSH terminal session channel (one `TerminalSessionClient` per visible leaf over the shared `RemoteHostConnection`).
""")
    func ipad_2_4_everyLeafUsesAnInteractiveSession() {
        #expect(MultiPaneDetailView.liveSessionNames(in: Self.layout) == [
            "left", "top", "bottom",
        ])
        #expect(SingleSessionView.sessionRole == .fullscreen)
    }

    @Test("""
@spec IPAD-2.5: While an iPad pane-layout leaf is not the display owner and the authoritative grid's column count exceeds the leaf's allotted width at the configured (iOS-scaled) font size, the application shall apply the same exact-grid canvas policy as `IOS-5.6` (per-leaf), initially fitting each leaf's canvas to the full leaf width before any local presentation zoom.
""")
    func ipad_2_5_embeddedLeafReusesSingleSessionCanvas() throws {
        let canvas = try #require(TerminalSnapshotCanvas.layout(
            grid: CGSize(width: 160, height: 40),
            measuredGrid: CGSize(width: 80, height: 24),
            measuredPixels: CGSize(width: 807, height: 487),
            cellPixels: CGSize(width: 10, height: 20),
            displayScale: 2,
            container: CGSize(width: 320, height: 240)
        ))
        #expect(canvas.size == CGSize(width: 803.5, height: 403.5))
        #expect(abs(canvas.size.width * canvas.scale - 320) < 0.001)
    }

    @Test("""
@spec IPAD-2.6: While a focused pane exists in the iPad split tree, the application shall apply the same Ghostty `unfocused-split-fill` and `unfocused-split-opacity` dimming treatment as the Mac to every other live pane, without drawing an iPad-only focus outline. When no pane is focused, no pane shall be dimmed.
""")
    func ipad_2_6_usesMacFocusDimmingWithoutOutline() {
        #expect(MultiPaneDetailView.isFocused(
            sessionName: "top",
            focusedPaneId: "top"
        ))
        #expect(!MultiPaneDetailView.isFocused(
            sessionName: "bottom",
            focusedPaneId: "top"
        ))
        #expect(MultiPaneDetailView.isUnfocused(
            sessionName: "bottom",
            focusedPaneId: "top"
        ))
        #expect(!MultiPaneDetailView.isUnfocused(
            sessionName: "bottom",
            focusedPaneId: nil
        ))
        #expect(GhosttyThemeColors.fallback.unfocusedSplitOpacity == 0.7)
        #expect(SingleSessionView.isTerminalKeyboardEligible(
            clientIsOwner: true,
            isPaneFocused: true
        ))
        #expect(!SingleSessionView.isTerminalKeyboardEligible(
            clientIsOwner: true,
            isPaneFocused: false
        ))
    }

    @Test("""
@spec IPAD-2.7: When the user drags an iPad workspace divider, the application shall persist the ratio in its device-local split tree without sending an RPC to the host or resetting the ratio when tabs change.
""")
    func dividerGeometryPersistsWithoutChangingHostLayout() throws {
        let defaults = UserDefaults(suiteName: "iPadGeometry-\(UUID())")!
        let host = UUID(), worktree = makeWorktree(layout: Self.layout)
        let store = MobileWorkspaceStore(defaults: defaults)
        store.synchronize(hostID: host, worktree: worktree, focused: "top")
        store.resize(hostID: host, worktree: worktree, path: .root.appending(.second), ratio: 0.32)
        let restored = MobileWorkspaceStore(defaults: defaults)
        restored.synchronize(hostID: host, worktree: worktree, focused: "bottom")
        guard case .split(_, _, _, let second) = restored.layout(hostID: host, worktree: worktree).root,
              case .split(_, let ratio, _, _) = second else {
            Issue.record("Expected nested split geometry"); return
        }
        #expect(ratio == 0.32)
        #expect(worktree.layout == Self.layout)
    }

    private func makeView(
        worktree: WorktreePanes,
        focusedPaneId: String?
    ) -> MultiPaneDetailView {
        MultiPaneDetailView(
            host: Host(
                id: UUID(),
                label: "test",
                baseURL: URL(string: "https://test.local")!,
                addedAt: Date(),
                lastUsedAt: nil
            ),
            worktree: worktree,
            theme: .fallback,
            focusedPaneId: focusedPaneId,
            pendingFocusRequests: 0,
            onFocusRequestsConsumed: {},
            ghosttyCommandContext: MobileGhosttyCommandContext(
                keybindingSet: .loading,
                perform: { _ in },
                isEnabled: { _ in false }
            ),
            onSelectPane: { _ in },
            onBackToWorktrees: {},
            workspaceStore: MobileWorkspaceStore(defaults: UserDefaults(suiteName: "MultiPaneDetail-\(UUID())")!)
        )
    }

    private func makeWorktree(layout: PaneLayoutNode) -> WorktreePanes {
        WorktreePanes(
            path: "/repo/feature",
            displayName: "feature",
            repoDisplayName: "repo",
            displayBranch: "feature",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: layout
        )
    }

    private static let layout = PaneLayoutNode.split(
        direction: .horizontal,
        ratio: 0.37,
        left: .leaf(
            sessionName: "left",
            title: "left",
            attentionText: nil,
            isBusy: false,
            attentionSource: nil
        ),
        right: .split(
            direction: .vertical,
            ratio: 0.61,
            left: .leaf(
                sessionName: "top",
                title: "top",
                attentionText: nil,
                isBusy: false,
                attentionSource: nil
            ),
            right: .leaf(
                sessionName: "bottom",
                title: "bottom",
                attentionText: nil,
                isBusy: false,
                attentionSource: nil
            )
        )
    )
}
#endif
