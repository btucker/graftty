import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct TransferableProjectMove: Codable, Transferable {
    static let contentType = UTType(exportedAs: "com.graftty.sidebar-project-move", conformingTo: .data)
    let projectID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }

    @MainActor @discardableResult
    func performMove(to target: String, placement: ProjectDropPlacement, projectIDs: [String],
                     allowsReordering: Bool, onMove: (String, String, Bool) -> Void) -> Bool {
        guard allowsReordering, projectID != target,
              projectIDs.contains(projectID), projectIDs.contains(target) else { return false }
        onMove(projectID, target, placement == .after)
        return true
    }
}

enum ProjectDropPlacement {
    case before, after

    init(location: CGPoint, rowHeight: CGFloat) {
        self = location.y < rowHeight / 2 ? .before : .after
    }
}

private struct ProjectDropDelegate: DropDelegate {
    let rowHeight: CGFloat
    let allowsReordering: Bool
    @Binding var placement: ProjectDropPlacement?
    let onDrop: (TransferableProjectMove, ProjectDropPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        allowsReordering && info.hasItemsConforming(to: [TransferableProjectMove.contentType])
    }

    func dropEntered(info: DropInfo) { updateIndicator(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(info)
        return DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { placement = nil }

    private func updateIndicator(_ info: DropInfo) {
        placement = validateDrop(info: info) ? ProjectDropPlacement(location: info.location, rowHeight: rowHeight) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        placement = nil
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [TransferableProjectMove.contentType]).first else { return false }
        let destination = ProjectDropPlacement(location: info.location, rowHeight: rowHeight)
        _ = provider.loadTransferable(type: TransferableProjectMove.self) { result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in onDrop(payload, destination) }
        }
        return true
    }
}

struct ProjectReorderTarget: ViewModifier {
    let projectID: String
    let allowsReordering: Bool
    let onSelect: () -> Void
    let onDrop: (TransferableProjectMove, ProjectDropPlacement) -> Void
    @State private var rowHeight: CGFloat = 44
    @State private var placement: ProjectDropPlacement?

    @ViewBuilder private func dragSource(_ content: Content) -> some View {
        #if os(macOS)
        content.overlay {
            ProjectDragSource(projectID: allowsReordering ? projectID : nil, onClick: onSelect)
        }
        #else
        if allowsReordering {
            content.draggable(TransferableProjectMove(projectID: projectID))
        } else {
            content
        }
        #endif
    }

    func body(content: Content) -> some View {
        dragSource(content)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
            .onDrop(of: [TransferableProjectMove.contentType], delegate: ProjectDropDelegate(
                rowHeight: rowHeight, allowsReordering: allowsReordering, placement: $placement, onDrop: onDrop))
            .overlay(alignment: placement == .after ? .bottom : .top) {
                if placement != nil {
                    Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                }
            }
    }
}

#if os(macOS)
import AppKit

final class ProjectDragPasteboardWriter: NSObject, NSPasteboardWriting {
    static let pasteboardType = NSPasteboard.PasteboardType(TransferableProjectMove.contentType.identifier)
    let data: Data

    init?(_ payload: TransferableProjectMove) {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        self.data = data
    }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] { [Self.pasteboardType] }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == Self.pasteboardType ? data : nil
    }
}

private struct ProjectDragSource: NSViewRepresentable {
    let projectID: String?
    let onClick: () -> Void

    func makeNSView(context: Context) -> SidebarRowDragSourceView {
        let view = SidebarRowDragSourceView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: SidebarRowDragSourceView, context: Context) {
        view.pasteboardWriter = projectID.flatMap { ProjectDragPasteboardWriter(.init(projectID: $0)) }
        view.onClick = onClick
    }
}
#endif
