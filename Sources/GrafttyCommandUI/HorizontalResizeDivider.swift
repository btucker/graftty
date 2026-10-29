import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A horizontal separator with a drag target shared by sidebar sections.
public struct HorizontalResizeDivider: View {
    private let label: String
    private let separatorIdentifier: String?
    private let onResize: (CGFloat) -> Void
    private let onResizeEnd: () -> Void

    public static var thickness: CGFloat {
        #if os(macOS)
        7
        #else
        44
        #endif
    }

    public init(label: String, separatorIdentifier: String? = nil,
                onResize: @escaping (CGFloat) -> Void, onResizeEnd: @escaping () -> Void) {
        self.label = label
        self.separatorIdentifier = separatorIdentifier
        self.onResize = onResize
        self.onResizeEnd = onResizeEnd
    }

    public var body: some View {
        #if os(macOS)
        NativeHorizontalResizeDivider(label: label, separatorIdentifier: separatorIdentifier,
            onResize: onResize, onResizeEnd: onResizeEnd)
            .frame(height: Self.thickness)
        #else
        Color.clear
            .overlay { Divider() }
            .overlay { Capsule().fill(.secondary).frame(width: 28, height: 4) }
            .frame(height: Self.thickness)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { onResize($0.translation.height) }
                .onEnded { value in
                    onResize(value.translation.height)
                    onResizeEnd()
                })
            .accessibilityLabel(label)
            .accessibilityIdentifier(label)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onResize(20)
                case .decrement: onResize(-20)
                @unknown default: return
                }
                onResizeEnd()
            }
        #endif
    }
}

#if os(macOS)
private struct NativeHorizontalResizeDivider: NSViewRepresentable {
    let label: String
    let separatorIdentifier: String?
    let onResize: (CGFloat) -> Void
    let onResizeEnd: () -> Void

    func makeNSView(context: Context) -> HorizontalResizeDividerView {
        let view = HorizontalResizeDividerView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HorizontalResizeDividerView, context: Context) {
        view.configure(label: label, separatorIdentifier: separatorIdentifier)
        view.onResize = onResize
        view.onResizeEnd = onResizeEnd
    }
}

final class HorizontalResizeDividerView: NSView {
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?
    private var startY: CGFloat?
    private let separator = HorizontalSeparatorBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(separator)
        toolTip = "Drag to resize sections"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(label: String, separatorIdentifier: String?) {
        setAccessibilityIdentifier(label)
        setAccessibilityLabel(label)
        separator.setAccessibilityIdentifier(separatorIdentifier)
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: floor(bounds.midY), width: bounds.width, height: 1)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) { startY = event.locationInWindow.y }

    override func mouseDragged(with event: NSEvent) {
        guard let startY else { return }
        onResize?(startY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) {
        startY = nil
        onResizeEnd?()
    }
}

/// NSBox adds two points above and below its separator alignment rect.
/// Keep the native bounds inside the one-point separator allocation.
private final class HorizontalSeparatorBox: NSBox {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

#endif
