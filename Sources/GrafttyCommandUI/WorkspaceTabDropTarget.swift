import CoreTransferable
import SwiftUI
import GrafttyProtocol
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

public struct WorkspaceTabDrag: Codable, Transferable {
    public static let contentType = UTType(exportedAs: "com.graftty.workspace-tab", conformingTo: .data)
    public let session: String
    public init(_ session: String) { self.session = session }
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

/// Per-tab targets keep insertion positions independent of scrolling and
/// variable label widths. The caller validates the session against its layout.
public struct WorkspaceTabDropTarget: ViewModifier {
    let onDrop: @MainActor (String, Bool) -> Void
    /// Vertical targets, such as gallery tiles, insert above or below.
    let vertical: Bool
    @State private var width: CGFloat = 1
    @State private var after: Bool?

    public init(vertical: Bool = false, onDrop: @escaping @MainActor (String, Bool) -> Void) {
        self.vertical = vertical
        self.onDrop = onDrop
    }

    public func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { vertical ? $0.size.height : $0.size.width } action: { width = $0 }
            .onDrop(of: [WorkspaceTabDrag.contentType],
                    delegate: TabDropDelegate(width: width, vertical: vertical, after: $after, onDrop: onDrop))
            .overlay(alignment: vertical ? (after == true ? .bottom : .top) : (after == true ? .trailing : .leading)) {
                if after != nil {
                    Rectangle().fill(Color.accentColor)
                        .frame(width: vertical ? nil : 2, height: vertical ? 2 : nil)
                        .offset(y: vertical ? (after == true ? 5 : -5) : 0)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct TabDropDelegate: DropDelegate {
    let width: CGFloat
    let vertical: Bool
    @Binding var after: Bool?
    let onDrop: @MainActor (String, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [WorkspaceTabDrag.contentType]) }
    func dropEntered(info: DropInfo) { after = (vertical ? info.location.y : info.location.x) >= width / 2 }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        after = (vertical ? info.location.y : info.location.x) >= width / 2
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { after = nil }
    func performDrop(info: DropInfo) -> Bool {
        after = nil
        guard let provider = info.itemProviders(for: [WorkspaceTabDrag.contentType]).first else { return false }
        let insertAfter = (vertical ? info.location.y : info.location.x) >= width / 2
        _ = provider.loadTransferable(type: WorkspaceTabDrag.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in onDrop(payload.session, insertAfter) }
        }
        return true
    }
}

/// A stage pane as a drop target for an agent tile. While a tile is dragged
/// over it, the half the agent would take is highlighted, or the whole pane
/// when the drop would replace what it shows (LAYOUT-2.261).
public struct WorkspaceStageDropTarget: ViewModifier {
    public typealias Edge = WorkspaceLayout<String>.Edge
    enum Target: Equatable { case split(Edge), replace }

    let onDrop: @MainActor (String, Edge?) -> Void
    @State private var size = CGSize.zero
    @State private var target: Target?

    public init(onDrop: @escaping @MainActor (String, Edge?) -> Void) { self.onDrop = onDrop }

    /// The part of a pane of `size` an agent dropped at `edge` would take.
    public static func highlight(_ edge: Edge?, in size: CGSize) -> CGRect {
        switch edge {
        case .left?: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right?: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top?: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom?: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case nil: CGRect(origin: .zero, size: size)
        }
    }

    static func label(_ edge: Edge?) -> String {
        switch edge {
        case .left?: "Split left"
        case .right?: "Split right"
        case .top?: "Split above"
        case .bottom?: "Split below"
        case nil: "Replace"
        }
    }

    public func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onDrop(of: [WorkspaceTabDrag.contentType], delegate: StageDropDelegate(size: size, target: $target, onDrop: onDrop))
            .overlay(alignment: .topLeading) {
                if let target {
                    let edge: Edge? = if case .split(let edge) = target { edge } else { nil }
                    let rect = Self.highlight(edge, in: size)
                    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                    shape.fill(Color.accentColor.opacity(0.18))
                        .overlay { shape.strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2) }
                        .overlay {
                            Text(Self.label(edge)).font(.caption.weight(.medium))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(3)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                        .animation(.snappy(duration: 0.12), value: target)
                }
            }
    }
}

private struct StageDropDelegate: DropDelegate {
    let size: CGSize
    @Binding var target: WorkspaceStageDropTarget.Target?
    let onDrop: @MainActor (String, WorkspaceStageDropTarget.Edge?) -> Void

    private func edge(_ info: DropInfo) -> WorkspaceStageDropTarget.Edge? {
        WorkspaceLayout<String>.dropEdge(x: info.location.x, y: info.location.y, width: size.width, height: size.height)
    }
    private func update(_ info: DropInfo) { target = edge(info).map { .split($0) } ?? .replace }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [WorkspaceTabDrag.contentType]) }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { target = nil }
    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let provider = info.itemProviders(for: [WorkspaceTabDrag.contentType]).first else { return false }
        let edge = edge(info)
        _ = provider.loadTransferable(type: WorkspaceTabDrag.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in onDrop(payload.session, edge) }
        }
        return true
    }
}

#if os(macOS)
/// Buttons can consume the mouse press before SwiftUI starts a drag on Mac.
/// Reuse the sidebar's native press/drag handling while keeping the Button's
/// keyboard and accessibility action and passing through contextual clicks.
private struct WorkspaceTabDragSourceOverlay: NSViewRepresentable {
    let session: String
    let onSelect: () -> Void

    func makeNSView(context: Context) -> SidebarRowDragSourceView {
        let view = SidebarRowDragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SidebarRowDragSourceView, context: Context) {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(WorkspaceTabDrag(session)),
           item.setData(data, forType: .init(WorkspaceTabDrag.contentType.identifier)) {
            view.pasteboardWriter = item
        } else {
            view.pasteboardWriter = nil
        }
        view.onClick = onSelect
    }
}
#endif

public extension View {
    @ViewBuilder
    func workspaceTabDragSource(_ session: String, onSelect: @escaping () -> Void) -> some View {
        #if os(macOS)
        overlay(WorkspaceTabDragSourceOverlay(session: session, onSelect: onSelect))
        #else
        draggable(WorkspaceTabDrag(session))
        #endif
    }

    func workspaceTabUnderline(selected: Bool, color: Color) -> some View {
        accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? color.opacity(0.55) : .clear).frame(height: 2)
        }
    }
}
