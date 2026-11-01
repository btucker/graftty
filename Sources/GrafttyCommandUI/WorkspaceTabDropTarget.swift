import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var width: CGFloat = 1
    @State private var after: Bool?

    public init(onDrop: @escaping @MainActor (String, Bool) -> Void) {
        self.onDrop = onDrop
    }

    public func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onDrop(of: [WorkspaceTabDrag.contentType], delegate: TabDropDelegate(width: width, after: $after, onDrop: onDrop))
            .overlay(alignment: after == true ? .trailing : .leading) {
                if after != nil {
                    Rectangle().fill(Color.accentColor).frame(width: 2).allowsHitTesting(false)
                }
            }
    }
}

private struct TabDropDelegate: DropDelegate {
    let width: CGFloat
    @Binding var after: Bool?
    let onDrop: @MainActor (String, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [WorkspaceTabDrag.contentType]) }
    func dropEntered(info: DropInfo) { after = info.location.x >= width / 2 }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        after = info.location.x >= width / 2
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { after = nil }
    func performDrop(info: DropInfo) -> Bool {
        after = nil
        guard let provider = info.itemProviders(for: [WorkspaceTabDrag.contentType]).first else { return false }
        let insertAfter = info.location.x >= width / 2
        _ = provider.loadTransferable(type: WorkspaceTabDrag.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in onDrop(payload.session, insertAfter) }
        }
        return true
    }
}

public extension View {
    func workspaceTabUnderline(selected: Bool, color: Color) -> some View {
        accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? color.opacity(0.55) : .clear).frame(height: 2)
        }
    }
}
