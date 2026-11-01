import SwiftUI
import GrafttyCommandUI
import GrafttyKit
import GrafttyProtocol

/// The worktree's agent pane, which carries the scrollback map, and the timeline it maps.
struct AgentScrollbackMap {
    let terminalID: PaneSlotID
    let timeline: WorktreeTimeline
}

/// Recursively renders a SplitTree into terminal surface views.
struct TerminalContentView: View {
    @ObservedObject private var imagePreviews = ImagePreviewStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var terminalManager: TerminalManager
    let splitTree: Binding<SplitTree>
    let focusedPaneSlotID: PaneSlotID?
    let theme: GhosttyTheme
    let onFocusTerminal: (PaneSlotID) -> Void
    var previewWorktreePath: String? = nil
    var agentScrollbackMap: AgentScrollbackMap? = nil
    var paneHeader: ((PaneSlotID) -> AnyView)? = nil
    var paneContent: ((PaneSlotID) -> AnyView?)? = nil
    var paneDropTarget: ((PaneSlotID, AnyView) -> AnyView)? = nil
    /// Breathing room between leading-edge pane content and the sidebar
    /// divider. Pane headers stay flush so tab rows reach the window edge.
    var leadingContentInset: CGFloat = 0

    private var previewPane: PaneSlotID? {
        ImagePreviewLayout.visiblePane(tree: splitTree.wrappedValue, focused: focusedPaneSlotID)
    }

    var body: some View {
        terminalBody
            .overlay(alignment: .top) {
                ImagePreviewOverlay(pane: previewPane,
                                    preview: previewPane.flatMap { imagePreviews.previews[$0] },
                                    onDismiss: { if let pane = previewPane { imagePreviews.dismiss(pane) } },
                                    onPopOut: popOutPreview)
            }
            .clipped()
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: previewPane.flatMap { imagePreviews.previews[$0]?.id })
    }

    private var popOutPreview: (() -> Void)? {
        guard let path = previewWorktreePath, let pane = previewPane,
              let preview = imagePreviews.previews[pane] else { return nil }
        return { [weak terminalManager] in
            let entry = FilePreviewHistory.shared.entries(for: path).first { $0.id == preview.id }
                ?? FilePreviewHistory.Entry(preview: preview, pane: pane, worktreePath: path)
            FilePreviewWindows.shared.show(entry, inlinePane: pane,
                resolveInlineWorktree: { [weak terminalManager] pane in terminalManager?.worktreePath(for: pane) })
        }
    }

    @ViewBuilder
    private var terminalBody: some View {
        // Zoom fast-path: if one pane is zoomed, render only its leaf full-bleed.
        // All sibling surfaces remain alive in TerminalManager.surfaces — we're
        // only changing which views are mounted, not tearing down PTYs.
        if let zoomedID = splitTree.wrappedValue.zoomed, splitTree.wrappedValue.containsLeaf(zoomedID) {
            leafView(zoomedID, leading: true)
        } else {
            Group {
                if let root = splitTree.wrappedValue.root {
                    nodeView(root)
                } else {
                    Text("No terminal")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// Floating capsule shown over a follower pane to reclaim display
    /// ownership — the Mac analogue of the iOS fullscreen Take Control button.
    private func takeControlButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Take Control", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .padding(.top, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func nodeView(_ node: SplitTree.Node, leading: Bool = true) -> AnyView {
        switch node {
        case .leaf(let terminalID):
            return leafView(terminalID, leading: leading)

        case .split(let split):
            return splitView(split, leading: leading)
        }
    }

    private func leafView(_ terminalID: PaneSlotID, leading: Bool) -> AnyView {
        let inset = leading ? leadingContentInset : 0
        let content = AnyView(VStack(spacing: 0) {
            if let paneHeader { paneHeader(terminalID) }
            Group {
                if let replacement = paneContent?(terminalID) { replacement }
                else { surfaceView(terminalID) }
            }
            .padding(.leading, inset)
            .background(inset > 0 ? theme.background : .clear)
        })
        return paneDropTarget?(terminalID, content) ?? content
    }

    private func surfaceView(_ terminalID: PaneSlotID) -> AnyView {
        let isUnfocused = focusedPaneSlotID != nil && terminalID != focusedPaneSlotID
        let dimmingStyle = theme.paneFocusDimmingStyle(isUnfocused: isUnfocused)
        if let handle = terminalManager.handle(for: terminalID) {
            let tm = terminalManager
            let content = AnyView(
                SurfaceViewWrapper(handle: handle, theme: theme, onFocusTerminal: {
                    // AppKit consumes terminal clicks inside the scroll view.
                    // Reconcile model focus directly, without re-focusing all
                    // surfaces on every keystroke in the already active pane.
                    if focusedPaneSlotID != terminalID || tm.focusedTerminalID != terminalID {
                        onFocusTerminal(terminalID)
                    }
                })
                    .paneFocusDimming(fill: theme.unfocusedSplitFill, style: dimmingStyle)
                    // Mirror the iOS "Take Control" affordance (OWN-2.1):
                    // offered when another display client (iOS/web) owns this
                    // pane, and when the session is ownerless after a prior
                    // takeover (the remote owner disconnected) — in both
                    // states the Mac can reclaim without typing. Visibility
                    // tracks ownership changes reactively via
                    // TerminalManager's store observer.
                    .overlay(alignment: .top) {
                        if tm.attachmentFailures[terminalID] != nil {
                            HStack(spacing: 12) {
                                Label("Terminal disconnected", systemImage: "exclamationmark.triangle")
                                Button("Retry") { tm.retryAttachment(for: terminalID) }
                            }
                            .font(.callout)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(12)
                        } else if tm.canTakeDisplayControl(for: terminalID) {
                            takeControlButton {
                                _ = tm.takeDisplayControl(for: terminalID)
                            }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let map = agentScrollbackMap, map.terminalID == terminalID {
                            ScrollbackMapOverlayHost(model: handle.scrollbackMapModel, timeline: map.timeline)
                                .padding(10)
                        }
                    }
                    // A retry replaces the native view while preserving the
                    // pane ID. Rebuild the wrapper for the new surface too.
                    .id(ObjectIdentifier(handle))
                    .onTapGesture {
                        onFocusTerminal(terminalID)
                    }
                    .onAppear { tm.setVisible(true, for: terminalID) }
                    .onDisappear { tm.setVisible(false, for: terminalID) }
            )
            return content
        } else {
            return AnyView(
                Color.black
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
                    .paneFocusDimming(fill: theme.unfocusedSplitFill, style: dimmingStyle)
                    .id(terminalID)
            )
        }
    }

    private func splitView(_ split: SplitTree.Node.Split, leading: Bool) -> AnyView {
        // Persist ratio drags back into the owning `SplitTree` binding so
        // layouts survive across restarts. Identify the target split by
        // `(left.allLeaves.first, direction)` — stable during a drag and
        // unique enough in practice for all trees our UI can construct.
        let leftAnchor = split.left.allLeaves.first
        let direction = split.direction
        let treeBinding = splitTree
        return AnyView(
            SplitRatioContainer(
                direction: direction,
                initialRatio: split.ratio,
                left: { nodeView(split.left, leading: leading) },
                // Only a stacked split's second child shares the leading edge.
                right: { nodeView(split.right, leading: leading && direction == .vertical) },
                onRatioChange: { newRatio in
                    guard let anchor = leftAnchor else { return }
                    treeBinding.wrappedValue = treeBinding.wrappedValue.updatingRatio(
                        leftAnchor: anchor,
                        direction: direction,
                        ratio: newRatio
                    )
                }
            )
        )
    }
}

/// Helper to give SplitContainerView a @State for the ratio binding.
private struct SplitRatioContainer<Left: View, Right: View>: View {
    let direction: SplitDirection
    let sourceRatio: Double
    @State var ratio: Double
    let left: () -> Left
    let right: () -> Right
    let onRatioChange: (Double) -> Void

    init(
        direction: SplitDirection,
        initialRatio: Double,
        @ViewBuilder left: @escaping () -> Left,
        @ViewBuilder right: @escaping () -> Right,
        onRatioChange: @escaping (Double) -> Void
    ) {
        self.direction = direction
        self.sourceRatio = initialRatio
        self._ratio = State(initialValue: initialRatio)
        self.left = left
        self.right = right
        self.onRatioChange = onRatioChange
    }

    var body: some View {
        // Persist only at drag end — intermediate mouse events update the
        // local `@State ratio` (which drives child frames directly), so
        // the tree-level SplitTree binding is written once per gesture.
        // Writing on every `.onChange` would re-render every sibling pane
        // and churn PTY winsize updates through zmx on every frame.
        SplitContainerView(
            direction: direction,
            ratio: $ratio,
            left: left(),
            right: right(),
            onDragEnd: { finalRatio in
                onRatioChange(finalRatio)
            }
        )
        .onChange(of: sourceRatio) { _, newRatio in
            ratio = newRatio
        }
    }
}
