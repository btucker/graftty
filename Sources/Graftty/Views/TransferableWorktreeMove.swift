import CoreTransferable
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GrafttyKit

/// Drag-payload for reordering worktree rows inside one sidebar repo
/// section. Kept separate from `TransferablePaneSlotID` so pane moves
/// and worktree moves cannot share a decoded payload.
struct TransferableWorktreeMove: Codable, Transferable {
    static let contentType = UTType(exportedAs: "com.graftty.sidebar-worktree-move", conformingTo: .data)

    let repoID: RepoEntry.ID
    let worktreeID: WorktreeEntry.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}

enum WorktreeDropPlacement: Equatable {
    case before
    case after

    static func fromRowDropLocation(
        _ location: CGPoint,
        rowHeight: CGFloat
    ) -> WorktreeDropPlacement {
        location.y < rowHeight / 2 ? .before : .after
    }
}

enum WorktreeDropReorder {
    @discardableResult
    static func apply(
        _ payload: TransferableWorktreeMove,
        targetWorktreeID: WorktreeEntry.ID,
        placement: WorktreeDropPlacement,
        to appState: inout AppState
    ) -> Bool {
        guard let repo = appState.repos.first(where: { $0.id == payload.repoID }),
              let source = repo.worktrees.first(where: { $0.id == payload.worktreeID }),
              let target = repo.worktrees.first(where: { $0.id == targetWorktreeID }) else { return false }
        return SidebarHostNavigation.moveWorktree(in: &appState, repositoryID: repo.path,
                                                 worktreeID: source.path, relativeTo: target.path,
                                                 after: placement == .after)
    }

}

/// One destination imports both payloads so pane drops cannot shadow reordering.
enum WorktreeRowDrop: Transferable {
    case worktree(TransferableWorktreeMove)
    case pane(TransferablePaneSlotID)

    static let contentTypes = [TransferableWorktreeMove.contentType, TransferablePaneSlotID.contentType]
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { WorktreeRowDrop.worktree($0 as TransferableWorktreeMove) })
        ProxyRepresentation(importing: { WorktreeRowDrop.pane($0 as TransferablePaneSlotID) })
    }

    enum Result: Equatable {
        case rejected
        case reordered
        case movePane(PaneSlotID, String)
    }

    func apply(repoID: RepoEntry.ID, targetWorktreeID: WorktreeEntry.ID,
               placement: WorktreeDropPlacement, allowsReordering: Bool,
               to state: inout AppState) -> Result {
        guard let repo = state.repos.first(where: { $0.id == repoID }),
              let target = repo.worktrees.first(where: { $0.id == targetWorktreeID }),
              !target.state.isInFlight else { return .rejected }
        switch self {
        case .worktree(let payload):
            guard allowsReordering, payload.repoID == repoID else { return .rejected }
            return WorktreeDropReorder.apply(payload, targetWorktreeID: targetWorktreeID,
                                             placement: placement, to: &state) ? .reordered : .rejected
        case .pane(let payload):
            let slot = PaneSlotID(id: payload.id)
            guard let indices = state.indicesOfWorktreeContaining(terminalID: slot),
                  state.repos[indices.repo].id == repoID else { return .rejected }
            return .movePane(slot, target.path)
        }
    }
}

private struct WorktreeRowDropDelegate: DropDelegate {
    let rowHeight: CGFloat
    let allowsReordering: Bool
    let isInFlight: Bool
    @Binding var placement: WorktreeDropPlacement?
    let onPaneTargeted: (Bool) -> Void
    let onDrop: (WorktreeRowDrop, WorktreeDropPlacement) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !isInFlight && (info.hasItemsConforming(to: [TransferablePaneSlotID.contentType])
            || (allowsReordering && info.hasItemsConforming(to: [TransferableWorktreeMove.contentType])))
    }

    func dropEntered(info: DropInfo) { updateIndicator(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        updateIndicator(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { clearIndicator() }

    private func updateIndicator(_ info: DropInfo) {
        guard validateDrop(info: info) else { clearIndicator(); return }
        let isWorktree = info.hasItemsConforming(to: [TransferableWorktreeMove.contentType])
        placement = isWorktree ? WorktreeDropPlacement.fromRowDropLocation(info.location, rowHeight: rowHeight) : nil
        onPaneTargeted(!isWorktree)
    }
    private func clearIndicator() { placement = nil; onPaneTargeted(false) }

    func performDrop(info: DropInfo) -> Bool {
        clearIndicator()
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: WorktreeRowDrop.contentTypes).first else { return false }
        let destination = WorktreeDropPlacement.fromRowDropLocation(info.location, rowHeight: rowHeight)
        _ = provider.loadTransferable(type: WorktreeRowDrop.self) { result in
            Task { @MainActor in
                if case .success(let payload) = result { onDrop(payload, destination) }
            }
        }
        return true
    }
}

/// @spec LAYOUT-2.67: While dragging a worktree, the application shall preview its heading and visible pane rows together at the sidebar row width while retaining separate pane drag gestures.
struct WorktreeReorderTarget: ViewModifier {
    let repoID: RepoEntry.ID
    let worktreeID: WorktreeEntry.ID
    @Binding var appState: AppState
    var isEnabled: Bool = true
    let preview: AnyView
    let onMovePane: (PaneSlotID, String) -> Void
    let onPaneTargeted: (Bool) -> Void
    @State private var rowSize: CGSize = .init(width: 280, height: 28)
    @State private var placement: WorktreeDropPlacement?

    private var worktree: WorktreeEntry? {
        appState.repos.first { $0.id == repoID }?.worktrees.first { $0.id == worktreeID }
    }
    private var canDrag: Bool {
        guard isEnabled, let worktree,
              let repo = appState.repos.first(where: { $0.id == repoID }) else { return false }
        return worktree.path != repo.path && !worktree.state.isInFlight
    }

    @ViewBuilder private func dragSource(_ content: Content) -> some View {
        if canDrag {
            content.draggable(TransferableWorktreeMove(repoID: repoID, worktreeID: worktreeID)) {
                preview.frame(width: rowSize.width).fixedSize(horizontal: false, vertical: true)
            }
        }
        else { content }
    }

    func body(content: Content) -> some View {
        dragSource(content)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { rowSize = $0 }
            .onDrop(of: WorktreeRowDrop.contentTypes, delegate: WorktreeRowDropDelegate(
                rowHeight: rowSize.height, allowsReordering: isEnabled,
                isInFlight: worktree?.state.isInFlight ?? true,
                placement: $placement, onPaneTargeted: onPaneTargeted,
                onDrop: { payload, destination in
                    let result = payload.apply(repoID: repoID, targetWorktreeID: worktreeID, placement: destination,
                                  allowsReordering: isEnabled, to: &appState)
                    // Invoke pane moves after releasing the state binding's writeback.
                    if case .movePane(let slot, let path) = result { onMovePane(slot, path) }
                }))
            .overlay(alignment: placement == .after ? .bottom : .top) {
                if placement != nil { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) }
            }
    }
}

extension View {
    func worktreeReorderTarget(
        repoID: RepoEntry.ID,
        worktreeID: WorktreeEntry.ID,
        appState: Binding<AppState>,
        isEnabled: Bool = true,
        preview: AnyView,
        onMovePane: @escaping (PaneSlotID, String) -> Void,
        onPaneTargeted: @escaping (Bool) -> Void
    ) -> some View {
        modifier(WorktreeReorderTarget(
            repoID: repoID, worktreeID: worktreeID,
            appState: appState, isEnabled: isEnabled, preview: preview,
            onMovePane: onMovePane, onPaneTargeted: onPaneTargeted
        ))
    }
}
