import GrafttyProtocol
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Cross-platform split renderer shared by the Mac terminal tree and the
/// regular-width iPad terminal tree. The ratio changes continuously while the
/// divider is dragged; `onDragEnd` fires once so callers can persist or retain
/// the final value without rebuilding their full pane hierarchy on every tick.
public struct ProportionalSplitView<First: View, Second: View>: View {
    public let direction: PaneLayoutNode.SplitAxis
    @Binding public var ratio: Double
    public let first: First
    public let second: Second
    public let onDragEnd: (Double) -> Void

    private let dividerThickness: CGFloat = 4
    private let minRatio = 0.1
    private let maxRatio = 0.9

    public init(
        direction: PaneLayoutNode.SplitAxis,
        ratio: Binding<Double>,
        first: First,
        second: Second,
        onDragEnd: @escaping (Double) -> Void
    ) {
        self.direction = direction
        self._ratio = ratio
        self.first = first
        self.second = second
        self.onDragEnd = onDragEnd
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                switch direction {
                case .horizontal:
                    HStack(spacing: 0) {
                        first.frame(
                            width: max(
                                0,
                                geometry.size.width * ratio - dividerThickness / 2
                            )
                        )
                        divider(isHorizontal: true, size: geometry.size)
                        second.frame(
                            width: max(
                                0,
                                geometry.size.width * (1 - ratio) - dividerThickness / 2
                            )
                        )
                    }
                case .vertical:
                    VStack(spacing: 0) {
                        first.frame(
                            height: max(
                                0,
                                geometry.size.height * ratio - dividerThickness / 2
                            )
                        )
                        divider(isHorizontal: false, size: geometry.size)
                        second.frame(
                            height: max(
                                0,
                                geometry.size.height * (1 - ratio) - dividerThickness / 2
                            )
                        )
                    }
                }
            }
            .coordinateSpace(name: CoordinateSpace.name)
        }
    }

    private func divider(isHorizontal: Bool, size: CGSize) -> some View {
        Rectangle()
            .fill(separatorColor)
            .frame(
                width: isHorizontal ? dividerThickness : nil,
                height: isHorizontal ? nil : dividerThickness
            )
            .modifier(ResizeCursorModifier(isHorizontal: isHorizontal))
            .gesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(CoordinateSpace.name)
                )
                .onChanged { value in
                    let total = isHorizontal ? size.width : size.height
                    let position = isHorizontal
                        ? value.location.x
                        : value.location.y
                    ratio = Self.clampedRatio(
                        position: position,
                        total: total,
                        minimum: minRatio,
                        maximum: maxRatio
                    )
                }
                .onEnded { _ in
                    onDragEnd(ratio)
                }
            )
    }

    public static func clampedRatio(
        position: CGFloat,
        total: CGFloat,
        minimum: Double = 0.1,
        maximum: Double = 0.9
    ) -> Double {
        guard total > 0 else { return minimum }
        return min(maximum, max(minimum, Double(position / total)))
    }

    private var separatorColor: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #elseif canImport(UIKit)
        Color(uiColor: .separator)
        #else
        Color.secondary
        #endif
    }

    private enum CoordinateSpace {
        static var name: String { "ProportionalSplitView.container" }
    }
}

private struct ResizeCursorModifier: ViewModifier {
    let isHorizontal: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.onHover { inside in
            if inside {
                (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
                    .push()
            } else {
                NSCursor.pop()
            }
        }
        #else
        content
        #endif
    }
}
