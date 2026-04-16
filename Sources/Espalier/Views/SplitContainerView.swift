import SwiftUI
import EspalierKit

/// A view that renders two children with a draggable divider.
struct SplitContainerView<Left: View, Right: View>: View {
    let direction: SplitDirection
    @Binding var ratio: Double
    let left: Left
    let right: Right

    private let dividerThickness: CGFloat = 4
    private let minRatio: Double = 0.1
    private let maxRatio: Double = 0.9

    var body: some View {
        GeometryReader { geo in
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
                DragGesture()
                    .onChanged { value in
                        let total = isHorizontal ? size.width : size.height
                        let position = isHorizontal ? value.location.x : value.location.y
                        let newRatio = Double(position / total)
                        ratio = min(maxRatio, max(minRatio, newRatio))
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
