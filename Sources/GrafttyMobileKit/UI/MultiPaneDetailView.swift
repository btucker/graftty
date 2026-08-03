#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

/// The regular-width iPad terminal surface. It renders the Mac-provided pane
/// tree directly and mounts one real, ownership-aware terminal session in
/// every leaf. The selected leaf is the sole UIKit keyboard owner, but all
/// sibling panes remain connected, live, and interactive for scrolling.
struct MultiPaneDetailView: View {
    let host: Host
    let worktree: WorktreePanes
    let coordinator: RemoteConnectionCoordinator
    let theme: GhosttyThemeColors
    let focusedPaneId: String?
    let pendingFocusRequests: Int
    let onFocusRequestsConsumed: () -> Void
    let autoTakeControlRequestCount: Int
    let autoTakeControlPolicy: SingleSessionView.AutoTakeControlPolicy
    let ghosttyCommandContext: MobileGhosttyCommandContext
    let onSelectPane: (String) -> Void
    let onBackToWorktrees: () -> Void

    @State private var ratioOverrides = IPadPaneRatioOverrides()
    @State private var keyboardBottomInset: CGFloat = 0

    var body: some View {
        Group {
            if let layout = worktree.layout {
                render(layout, at: .root)
            } else {
                ContentUnavailableView(
                    "No panes running",
                    systemImage: "terminal"
                )
            }
        }
        .padding(.bottom, keyboardBottomInset)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification
        )) { notification in
            guard let value = notification.userInfo?[
                UIResponder.keyboardFrameEndUserInfoKey
            ] as? NSValue else {
                return
            }
            let inset = KeyboardFrameInset.bottomInset(
                keyboardEndFrame: value.cgRectValue,
                screenBounds: UIScreen.main.bounds
            )
            if keyboardBottomInset != inset {
                keyboardBottomInset = inset
            }
        }
        .animation(.easeInOut(duration: 0.25), value: keyboardBottomInset)
    }

    private func render(
        _ node: PaneLayoutNode,
        at path: IPadPaneTreePath
    ) -> AnyView {
        switch node {
        case let .leaf(sessionName, title, _, _, _, _):
            let isFocused = Self.isFocused(
                sessionName: sessionName,
                focusedPaneId: focusedPaneId
            )
            let isUnfocused = Self.isUnfocused(
                sessionName: sessionName,
                focusedPaneId: focusedPaneId
            )
            return AnyView(
                MultiPaneLeafView(
                    host: host,
                    sessionName: sessionName,
                    title: title.isEmpty ? sessionName : title,
                    coordinator: coordinator,
                    theme: theme,
                    isFocused: isFocused,
                    isUnfocused: isUnfocused,
                    pendingFocusRequests: isFocused ? pendingFocusRequests : 0,
                    onFocusRequestsConsumed: onFocusRequestsConsumed,
                    autoTakeControlRequestCount: isFocused
                        ? autoTakeControlRequestCount
                        : 0,
                    autoTakeControlPolicy: autoTakeControlPolicy,
                    ghosttyCommandContext: ghosttyCommandContext,
                    onSelect: {
                        guard focusedPaneId != sessionName else { return }
                        onSelectPane(sessionName)
                    },
                    onBackToWorktrees: onBackToWorktrees
                )
                .id(sessionName)
            )

        case let .split(direction, ratio, first, second):
            let identity = IPadPaneSplitIdentity(
                path: path,
                direction: direction,
                firstAnchor: first.leaves.first?.sessionName,
                secondAnchor: second.leaves.first?.sessionName
            )
            let ratioOverride = Binding<Double?>(
                get: { ratioOverrides[identity] },
                set: { value in
                    ratioOverrides[identity] = value
                }
            )
            return AnyView(
                MultiPaneSplitNode(
                    direction: direction,
                    sourceRatio: ratio,
                    ratioOverride: ratioOverride,
                    first: render(first, at: path.appending(.first)),
                    second: render(second, at: path.appending(.second))
                )
                .id(identity.renderIdentity)
            )
        }
    }

    static func liveSessionNames(in layout: PaneLayoutNode?) -> [String] {
        layout?.leaves.map(\.sessionName) ?? []
    }

    static func isFocused(
        sessionName: String,
        focusedPaneId: String?
    ) -> Bool {
        sessionName == focusedPaneId
    }

    static func isUnfocused(
        sessionName: String,
        focusedPaneId: String?
    ) -> Bool {
        focusedPaneId != nil && sessionName != focusedPaneId
    }
}

struct IPadPaneSplitIdentity: Hashable {
    let path: IPadPaneTreePath
    let direction: PaneLayoutNode.SplitAxis
    let firstAnchor: String?
    let secondAnchor: String?

    /// SwiftUI node identity stays path-stable so topology edits preserve
    /// surviving terminal views. The full identity remains the ratio-cache key.
    var renderIdentity: IPadPaneTreePath { path }
}

struct IPadPaneTreePath: Hashable {
    enum Branch: Hashable {
        case first
        case second
    }

    static let root = IPadPaneTreePath(branches: [])

    let branches: [Branch]

    func appending(_ branch: Branch) -> IPadPaneTreePath {
        IPadPaneTreePath(branches: branches + [branch])
    }
}

struct IPadPaneRatioOverrides {
    private var values: [IPadPaneSplitIdentity: Double] = [:]

    subscript(identity: IPadPaneSplitIdentity) -> Double? {
        get { values[identity] }
        set { values[identity] = newValue }
    }

    func ratio(
        at identity: IPadPaneSplitIdentity,
        sourceRatio: Double
    ) -> Double {
        values[identity] ?? sourceRatio
    }
}

private struct MultiPaneSplitNode: View {
    let direction: PaneLayoutNode.SplitAxis
    let sourceRatio: Double
    @Binding var ratioOverride: Double?
    let first: AnyView
    let second: AnyView

    @State private var displayedRatio: Double

    init(
        direction: PaneLayoutNode.SplitAxis,
        sourceRatio: Double,
        ratioOverride: Binding<Double?>,
        first: AnyView,
        second: AnyView
    ) {
        self.direction = direction
        self.sourceRatio = sourceRatio
        self._ratioOverride = ratioOverride
        self.first = first
        self.second = second
        self._displayedRatio = State(
            initialValue: ratioOverride.wrappedValue ?? sourceRatio
        )
    }

    var body: some View {
        ProportionalSplitView(
            direction: direction,
            ratio: $displayedRatio,
            first: first,
            second: second,
            onDragEnd: { ratioOverride = $0 }
        )
        .onChange(of: sourceRatio) { _, newRatio in
            guard ratioOverride == nil else { return }
            displayedRatio = newRatio
        }
        .onChange(of: ratioOverride) { _, override in
            displayedRatio = override ?? sourceRatio
        }
    }
}

private struct MultiPaneLeafView: View {
    let host: Host
    let sessionName: String
    let title: String
    let coordinator: RemoteConnectionCoordinator
    let theme: GhosttyThemeColors
    let isFocused: Bool
    let isUnfocused: Bool
    let pendingFocusRequests: Int
    let onFocusRequestsConsumed: () -> Void
    let autoTakeControlRequestCount: Int
    let autoTakeControlPolicy: SingleSessionView.AutoTakeControlPolicy
    let ghosttyCommandContext: MobileGhosttyCommandContext
    let onSelect: () -> Void
    let onBackToWorktrees: () -> Void

    @State private var unusedNavigationPath = NavigationPath()

    var body: some View {
        SingleSessionView(
            step: SessionStep(
                host: host,
                sessionName: sessionName,
                title: title
            ),
            navigationPath: $unusedNavigationPath,
            isFullScreen: false,
            coordinator: coordinator,
            externalPendingFocusRequests: pendingFocusRequests,
            onExternalFocusRequestsConsumed: onFocusRequestsConsumed,
            autoTakeControlRequestCount: autoTakeControlRequestCount,
            autoTakeControlPolicy: autoTakeControlPolicy,
            ghosttyCommandContext: ghosttyCommandContext,
            isPaneFocused: isFocused,
            isEmbeddedPane: true,
            onPaneInteraction: onSelect,
            onBackToWorktrees: onBackToWorktrees
        )
        .paneFocusDimming(
            fill: theme.unfocusedSplitFill,
            style: PaneFocusDimmingStyle(
                isUnfocused: isUnfocused,
                contentOpacity: theme.unfocusedSplitOpacity
            )
        )
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
#endif
