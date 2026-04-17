import SwiftUI
import EspalierKit

/// Recursively renders a SplitTree into terminal surface views.
struct TerminalContentView: View {
    @ObservedObject var terminalManager: TerminalManager
    let splitTree: Binding<SplitTree>
    let onFocusTerminal: (TerminalID) -> Void

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

    private func nodeView(_ node: SplitTree.Node) -> AnyView {
        switch node {
        case .leaf(let terminalID):
            return leafView(terminalID)

        case .split(let split):
            return splitView(split)
        }
    }

    private func leafView(_ terminalID: TerminalID) -> AnyView {
        if let nsView = terminalManager.view(for: terminalID) {
            return AnyView(
                SurfaceViewWrapper(nsView: nsView)
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
            )
        } else {
            return AnyView(
                Color.black
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
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
        self._ratio = State(initialValue: initialRatio)
        self.left = left
        self.right = right
        self.onRatioChange = onRatioChange
    }

    var body: some View {
        SplitContainerView(
            direction: direction,
            ratio: $ratio,
            left: left(),
            right: right()
        )
        .onChange(of: ratio) { _, newValue in
            onRatioChange(newValue)
        }
    }
}
