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
@spec IPAD-2.1: While a worktree is selected and the iPad layout is regular-width, the detail column shall render `MultiPaneDetailView` over the worktree's `PaneLayoutNode`.
""")
    func ipad_2_1_usesCompleteMacPaneTree() {
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
@spec IPAD-2.5: While an iPad pane-layout leaf is not the display owner and the authoritative grid's column count exceeds the leaf's allotted width at the configured (iOS-scaled) font size, the application shall apply the same font-fit policy as `IOS-5.6` (per-leaf), rendering each leaf's pane at the full leaf width with no horizontal `ScrollView`.
""")
    func ipad_2_5_embeddedLeafReusesSingleSessionFontFit() {
        let decision = TerminalWidthLayout.decide(
            containerWidth: 320,
            authoritativeCols: 160,
            configFontSize: 11,
            measuredCellWidthPoints: nil,
            measuredAtFontSize: nil,
            isOwner: false
        )

        guard case .fitFont = decision else {
            Issue.record("Expected a per-leaf fit-font decision")
            return
        }
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
@spec IPAD-2.7: When the user drags a split's divider, the application shall update a per-iPad-client divider-ratio override map keyed by the tree path to that split, without sending any RPC to the host.
""")
    func ipad_2_7_ratioOverridesAreLocalAndPathScoped() {
        let first = IPadPaneTreePath.root.appending(.first)
        let second = IPadPaneTreePath.root.appending(.second)
        var overrides = IPadPaneRatioOverrides()

        overrides[first] = 0.32

        #expect(overrides.ratio(at: first, sourceRatio: 0.5) == 0.32)
        #expect(overrides.ratio(at: second, sourceRatio: 0.61) == 0.61)
        overrides[first] = nil
        #expect(overrides.ratio(at: first, sourceRatio: 0.5) == 0.5)
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
            coordinator: RemoteConnectionCoordinator(
                connectionsAllowedInitially: false
            ),
            theme: .fallback,
            focusedPaneId: focusedPaneId,
            pendingFocusRequests: 0,
            onFocusRequestsConsumed: {},
            autoTakeControlRequestCount: 0,
            autoTakeControlPolicy: .init(),
            ghosttyCommandContext: MobileGhosttyCommandContext(
                keybindingSet: .loading,
                perform: { _ in },
                isEnabled: { _ in false }
            ),
            onSelectPane: { _ in }
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
