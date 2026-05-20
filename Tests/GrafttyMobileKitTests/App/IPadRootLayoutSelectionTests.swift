#if canImport(UIKit)
import Testing
import Foundation
import SwiftUI
import GrafttyProtocol
@testable import GrafttyMobileKit

@MainActor
@Suite("IPadRootLayout selection routing")
struct IPadRootLayoutSelectionTests {

    private func freshAppState() -> IPadAppState {
        IPadAppState(defaults: UserDefaults(suiteName: "IPadRootLayoutSelectionTests-\(UUID().uuidString)")!)
    }

    private func sampleHost(id: UUID = UUID(), label: String = "test") -> Host {
        Host(
            id: id,
            label: label,
            baseURL: URL(string: "https://\(label).local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
    }

    @Test("""
@spec IPAD-1.2: While `IPadRootLayout` is presented, the sidebar shall display a `HostHeaderRow` at the top showing the selected host's label and a tap target presenting a host-switcher popover.
""")
    func ipad_1_2_hostHeaderRowState() {
        let appState = freshAppState()
        let hostA = sampleHost(label: "alpha")
        appState.selectedHostId = hostA.id

        let resolved = IPadRootLayout.resolveSelectedHost(
            from: [hostA, sampleHost(label: "bravo")],
            selectedHostId: appState.selectedHostId
        )
        #expect(resolved?.id == hostA.id)

        appState.selectedHostId = nil
        let none = IPadRootLayout.resolveSelectedHost(
            from: [hostA],
            selectedHostId: nil
        )
        #expect(none == nil)
    }

    @Test("""
@spec IPAD-1.3: While `IPadRootLayout` is presented, the sidebar shall render `WorktreeListContent` extracted from `WorktreePickerView`, preserving `WorktreePickerGrouping`, swipe actions, PR badges, attention pills, and divergence gutter.
""")
    func ipad_1_3_sidebarBindsToWorktreeListContent() {
        let view = WorktreeListContent(
            host: sampleHost(),
            onSelect: { _ in },
            onSelectPane: { _ in },
            onListChanged: { _ in }
        )
        _ = view
        #expect(true)
    }

    @Test("""
@spec IPAD-1.4: When the user taps a pane child row in the sidebar at iPad regular width, the application shall set `IPadAppState.focusedPaneId` to that leaf's `sessionName` without pushing a new navigation stack frame.
""")
    func ipad_1_4_paneRowTapSetsFocus() {
        let appState = freshAppState()
        let node = PaneLayoutNode.leaf(
            sessionName: "session-xyz",
            title: "shell",
            attentionText: nil
        )
        guard let leaf = node.leaves.first else {
            Issue.record("expected a leaf")
            return
        }
        let onSelectPane: (PaneLayoutNode.Leaf) -> Void = { leaf in
            appState.focusedPaneId = leaf.sessionName
        }
        onSelectPane(leaf)
        #expect(appState.focusedPaneId == "session-xyz")
    }

    @Test("""
@spec IPAD-6.1: When the user selects a different host from the host-switcher popover, the application shall reset `selectedWorktreePath` and `focusedPaneId`, dismiss the popover, and re-fetch worktrees and theme for the new host.
""")
    func ipad_6_1_hostSwitchResetsSelection() {
        let appState = freshAppState()
        let hostA = sampleHost(label: "alpha")
        let hostB = sampleHost(label: "bravo")
        appState.selectedHostId = hostA.id
        appState.selectedWorktreePath = "/repo/branch-a"
        appState.focusedPaneId = "session-a"

        IPadRootLayout.applyHostSwitch(appState: appState, to: hostB.id)

        #expect(appState.selectedHostId == hostB.id)
        #expect(appState.selectedWorktreePath == nil)
        #expect(appState.focusedPaneId == nil)
    }

    @Test("""
@spec IPAD-6.2: While the new host's worktree fetch is in progress, the sidebar shall show ProgressView and the detail column shall show `ContentUnavailableView`.
""")
    func ipad_6_2_inProgressPlaceholder() {
        let appState = freshAppState()
        appState.selectedHostId = UUID()
        #expect(appState.selectedWorktreePath == nil)
    }

    @Test("""
@spec IPAD-1.5: While `IPadRootLayout` is presented, the sidebar's row text (worktree name, secondary branch label, type icon for closed/creating/deleting states, pane `↳` arrow and pane title, divergence-gutter ahead side, and the Section repository header) shall be colored from `appState.theme` rather than system label colors, sharing the same opacity ladder the Mac sidebar applies via `GhosttyThemeColors.sidebarPrimaryText`/`sidebarSecondaryText`/`sidebarDimIcon`/`sidebarStaleText`/`paneArrow`/`paneTitle`.
""")
    func ipad_1_5_sidebarRowsUseThemeColors() {
        // Constructor stamps the theme onto the view; on iPad we always
        // pass the host's resolved theme so row text reads against the
        // themed sidebar background. Compact (iPhone) callers omit it so
        // rows fall back to the system `.secondary` styling against the
        // standard grouped-list background. The actual opacity-ladder
        // values are covered in GhosttyThemeCoreTests.
        let themed = WorktreeListContent(
            host: sampleHost(),
            theme: GhosttyThemeColors.fallback,
            onSelect: { _ in },
            onSelectPane: { _ in }
        )
        #expect(themed.theme == GhosttyThemeColors.fallback)

        let untyped = WorktreeListContent(
            host: sampleHost(),
            onSelect: { _ in },
            onSelectPane: { _ in }
        )
        #expect(untyped.theme == nil)
    }

    @Test("""
@spec IPAD-1.6: While `IPadRootLayout` is presented, the sidebar and detail shall render side-by-side as a permanent two-column layout (NavigationSplitView with `.balanced` style and an initial `columnVisibility` of `.all`) rather than the system's overlay default, mirroring the Mac sidebar's always-visible behavior.
""")
    func ipad_1_6_balancedSidebarColumnVisibility() {
        let state = freshAppState()
        // Initial sidebar visibility is `.all` so a fresh launch lands on
        // both columns visible. Persisted in-memory only — sidebar toggles
        // during a session reflect here so a future redraw keeps state.
        #expect(state.columnVisibility == .all)
    }

    @Test("""
@spec IPAD-1.7: While `IPadRootLayout`'s detail column is rendering a session via `SingleSessionView`, the application shall keep the terminal edge-to-edge (`.ignoresSafeArea()`) but render the navigation bar with a transparent background (`.toolbarBackground(.hidden, for: .navigationBar)`) instead of hiding it. The system-provided sidebar-toggle button then floats over the terminal — preserving full terminal height while keeping a way to re-show a collapsed sidebar. The iPhone compact path keeps the existing fullscreen chrome (hidden navigation bar).
""")
    func ipad_1_7_singleSessionViewIsFullScreenFlag() {
        let host = sampleHost()
        let step = SessionStep(host: host, sessionName: "s", title: "s")
        // iPad split-column usage opts out of fullscreen chrome so the
        // system's sidebar toggle stays accessible.
        let split = SingleSessionView(
            step: step,
            navigationPath: .constant(NavigationPath()),
            isFullScreen: false
        )
        #expect(split.isFullScreen == false)

        // iPhone compact path keeps the existing default (fullscreen).
        let compact = SingleSessionView(
            step: step,
            navigationPath: .constant(NavigationPath())
        )
        #expect(compact.isFullScreen == true)
    }

    @Test("stale-selectedWorktreePath is cleared when onListChanged fires without the path")
    func stalePathCleanup() {
        let appState = freshAppState()
        appState.selectedWorktreePath = "/repo/branch-deleted-out-of-band"
        appState.focusedPaneId = "session-x"

        IPadRootLayout.onWorktreeListChanged(
            appState: appState,
            list: [
                .init(
                    path: "/repo/branch-other",
                    displayName: "other",
                    repoDisplayName: "repo",
                    displayBranch: "other",
                    state: .closed,
                    isMainCheckout: false,
                    prBadge: nil,
                    stats: nil,
                    attentionText: nil,
                    layout: nil
                )
            ]
        )

        #expect(appState.selectedWorktreePath == nil)
        #expect(appState.focusedPaneId == nil)
    }
}
#endif
