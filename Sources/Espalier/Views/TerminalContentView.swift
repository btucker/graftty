import SwiftUI
import EspalierKit

/// Recursively renders a SplitTree into terminal surface views.
struct TerminalContentView: View {
    @ObservedObject var terminalManager: TerminalManager
    let splitTree: Binding<SplitTree>
    let onFocusTerminal: (TerminalID) -> Void

    var body: some View {
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
            )
        }
    }

    private func splitView(_ split: SplitTree.Node.Split) -> AnyView {
        AnyView(
            SplitRatioContainer(
                direction: split.direction,
                initialRatio: split.ratio,
                left: { nodeView(split.left) },
                right: { nodeView(split.right) },
                onRatioChange: { _ in
                    // Will be wired to AppState.updateRatio in integration
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
