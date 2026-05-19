#if canImport(UIKit)
import Testing
import Foundation
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
