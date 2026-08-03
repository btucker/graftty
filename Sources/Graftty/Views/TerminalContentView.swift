import SwiftUI
import GrafttyKit

/// Recursively renders a SplitTree into terminal surface views.
struct TerminalContentView: View {
    @ObservedObject var terminalManager: TerminalManager
    let splitTree: Binding<SplitTree>
    let focusedPaneSlotID: PaneSlotID?
    let theme: GhosttyTheme
    let onFocusTerminal: (PaneSlotID) -> Void

    var body: some View {
        // Zoom fast-path: if one pane is zoomed, render only its leaf full-bleed.
        // All sibling surfaces remain alive in TerminalManager.surfaces — we're
        // only changing which views are mounted, not tearing down PTYs.
        if let zoomedID = splitTree.wrappedValue.zoomed {
            leafView(zoomedID)
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

    private func nodeView(_ node: SplitTree.Node) -> AnyView {
        switch node {
        case .leaf(let terminalID):
            return leafView(terminalID)

        case .split(let split):
            return splitView(split)
        }
    }

    private func leafView(_ terminalID: PaneSlotID) -> AnyView {
        let isUnfocused = focusedPaneSlotID != nil && terminalID != focusedPaneSlotID
        let dimmingStyle = theme.paneFocusDimmingStyle(isUnfocused: isUnfocused)
        if let nsView = terminalManager.view(for: terminalID) {
            let tm = terminalManager
            return AnyView(
                SurfaceViewWrapper(nsView: nsView)
                    .paneFocusDimming(fill: theme.unfocusedSplitFill, style: dimmingStyle)
                    // Mirror the iOS "Take Control" affordance (OWN-2.1):
                    // offered when another display client (iOS/web) owns this
                    // pane, and when the session is ownerless after a prior
                    // takeover (the remote owner disconnected) — in both
                    // states the Mac can reclaim without typing. Visibility
                    // tracks ownership changes reactively via
                    // TerminalManager's store observer.
                    .overlay(alignment: .top) {
                        if tm.canTakeDisplayControl(for: terminalID) {
                            takeControlButton {
                                _ = tm.takeDisplayControl(for: terminalID)
                            }
                        }
                    }
                    // Force a distinct SwiftUI identity per terminal. Without
                    // this, when the split tree swaps one terminalID for
                    // another at the same structural position (e.g., the user
                    // switches worktrees), SwiftUI would reuse the existing
                    // NSViewRepresentable instance and call updateNSView with
                    // the ORIGINAL NSView — never swapping the on-screen
                    // terminal view. The .id() modifier ties view identity to
                    // the terminalID, so SwiftUI tears down the old wrapper
                    // and constructs a fresh one (makeNSView called again
                    // with the correct NSView).
                    .id(terminalID)
                    .onTapGesture {
                        onFocusTerminal(terminalID)
                    }
                    .onAppear { tm.setVisible(true, for: terminalID) }
            )
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

    private func splitView(_ split: SplitTree.Node.Split) -> AnyView {
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
                left: { nodeView(split.left) },
                right: { nodeView(split.right) },
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
