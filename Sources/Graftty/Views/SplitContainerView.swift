import SwiftUI
import GrafttyKit

/// A view that renders two children with a draggable divider.
struct SplitContainerView<Left: View, Right: View>: View {
    let direction: SplitDirection
    @Binding var ratio: Double
    let left: Left
    let right: Right
    /// Called once when the drag ends, with the final (clamped) ratio.
    /// Callers use this to persist the new ratio back into the owning
    /// `SplitTree` without rewriting the tree on every mouse event —
    /// which would re-invalidate the entire terminal view hierarchy and
    /// cause visible lag during the drag (especially under zmx, where
    /// each layout pass forwards SIGWINCH through a second PTY).
    let onDragEnd: (Double) -> Void

    private static var containerSpace: String { "SplitContainerView.container" }

    private let dividerThickness: CGFloat = 4
    private let minRatio: Double = 0.1
    private let maxRatio: Double = 0.9

    var body: some View {
        GeometryReader { geo in
            Group {
                if direction == .horizontal {
                    HStack(spacing: 0) {
                        left.frame(width: geo.size.width * ratio - dividerThickness / 2)
                        divider(isHorizontal: true, size: geo.size)
                        right.frame(width: geo.size.width * (1 - ratio) - dividerThickness / 2)
                    }
                } else {
                    VStack(spacing: 0) {
                        left.frame(height: geo.size.height * ratio - dividerThickness / 2)
                        divider(isHorizontal: false, size: geo.size)
                        right.frame(height: geo.size.height * (1 - ratio) - dividerThickness / 2)
                    }
                }
            }
            .coordinateSpace(name: Self.containerSpace)
        }
    }

    private func divider(isHorizontal: Bool, size: CGSize) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: isHorizontal ? dividerThickness : nil,
                height: isHorizontal ? nil : dividerThickness
            )
            .cursor(isHorizontal ? .resizeLeftRight : .resizeUpDown)
            .gesture(
                // Measure the drag in the *container's* coordinate space
                // (`named(containerSpace)`), not the divider's default
                // `.local` space. The divider is only `dividerThickness`
                // points wide, so local-space `value.location.x` reports
                // 0..4 and every drag collapses to `minRatio`. Named
                // coords measure the cursor against the full split, which
                // is the denominator we divide by below.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.containerSpace))
                    .onChanged { value in
                        let total = isHorizontal ? size.width : size.height
                        let position = isHorizontal ? value.location.x : value.location.y
                        ratio = DividerRatio.ratio(
                            position: position,
                            total: total,
                            minRatio: minRatio,
                            maxRatio: maxRatio
                        )
                    }
                    .onEnded { _ in
                        onDragEnd(ratio)
                    }
            )
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
