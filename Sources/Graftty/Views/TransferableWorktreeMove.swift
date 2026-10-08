import CoreTransferable
import CoreGraphics
import Foundation
import os
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
    static func pin(_ payload: TransferableWorktreeMove, repoID: UUID,
                    targetWorktreeID: UUID? = nil, placement: WorktreeDropPlacement = .after,
                    to state: inout AppState) -> Bool {
        guard payload.repoID == repoID,
              let repo = state.repos.first(where: { $0.id == repoID }),
              let source = repo.worktrees.first(where: { $0.id == payload.worktreeID }) else { return false }
        let target = targetWorktreeID.flatMap { id in repo.worktrees.first { $0.id == id } }
        guard targetWorktreeID == nil || target != nil else { return false }
        return SidebarHostNavigation.pinWorktree(in: &state, repositoryID: repo.path,
            worktreeID: source.path, relativeTo: target?.path, after: placement == .after)
    }

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
        case pinned
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
            if SidebarHostNavigation.isPinned(target, in: repo),
               let source = repo.worktrees.first(where: { $0.id == payload.worktreeID }), !source.isPinned {
                return WorktreeDropReorder.pin(payload, repoID: repoID, targetWorktreeID: targetWorktreeID,
                    placement: placement, to: &state) ? .pinned : .rejected
            }
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
    /// `log stream --predicate 'subsystem == "com.graftty.app" AND category == "sidebar-drag"'`
    private static let log = Logger(subsystem: "com.graftty.app", category: "sidebar-drag")
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

    func dropEntered(info: DropInfo) {
        // One line per drag entering a row: the first signal that a drag
        // session started at all, and whether this row's gate accepted it.
        Self.log.info("dropEntered valid=\(validateDrop(info: info), privacy: .public) reordering=\(allowsReordering, privacy: .public) inFlight=\(isInFlight, privacy: .public)")
        updateIndicator(info)
    }
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
                switch result {
                case .success(let payload): onDrop(payload, destination)
                case .failure(let error):
                    Self.log.error("loadTransferable failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        return true
    }
}

/// Bounds of independently clickable controls inside a worktree block.
/// The native selection target lets pane, badge, and report clicks through.
struct WorktreeHeadingAnchor: PreferenceKey {
    enum Region: Hashable { case heading, prBadge, reportButton, pane(PaneSlotID) }
    static let defaultValue: [Region: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Region: Anchor<CGRect>], nextValue: () -> [Region: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Drag source + drop target for one worktree block (heading + pane
/// rows). The source is an AppKit overlay (`WorktreeDragSourceOverlay`)
/// because SwiftUI's `.draggable` never began a session for these rows on
/// the project column; it selects and drags the block outside its controls.
/// Drops resolve against the block's midpoint, so a worktree lands before
/// or after another whole worktree, never between its panes.
struct WorktreeReorderTarget: ViewModifier {
    static func canDrag(_ worktree: WorktreeEntry, in repo: RepoEntry, isEnabled: Bool) -> Bool {
        isEnabled && worktree.path != repo.path && !worktree.state.isInFlight
    }

    let repoID: RepoEntry.ID
    let worktreeID: WorktreeEntry.ID
    @Binding var appState: AppState
    var isEnabled: Bool = true
    let onSelect: () -> Void
    let onMovePane: (PaneSlotID, String) -> Void
    let onPaneTargeted: (Bool) -> Void
    @State private var rowHeight: CGFloat = 28
    @State private var placement: WorktreeDropPlacement?

    private var worktree: WorktreeEntry? {
        appState.repos.first { $0.id == repoID }?.worktrees.first { $0.id == worktreeID }
    }
    private var canDrag: Bool {
        guard isEnabled, let worktree,
              let repo = appState.repos.first(where: { $0.id == repoID }) else { return false }
        return Self.canDrag(worktree, in: repo, isEnabled: isEnabled)
    }
    private var allowsReordering: Bool {
        guard isEnabled, let worktree,
              let repo = appState.repos.first(where: { $0.id == repoID }) else { return false }
        return repo.worktreeOrderMode == .manual || SidebarHostNavigation.isPinned(worktree, in: repo)
    }

    private func dragSource(_ content: Content) -> some View {
        content.overlayPreferenceValue(WorktreeHeadingAnchor.self) { anchors in
            GeometryReader { proxy in
                WorktreeDragSourceOverlay(
                    payload: canDrag ? TransferableWorktreeMove(repoID: repoID, worktreeID: worktreeID) : nil,
                    excludedRects: anchors.filter { $0.key != .heading }.map { proxy[$0.value] },
                    onClick: onSelect)
            }
        }
    }

    func body(content: Content) -> some View {
        dragSource(content)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
            .onDrop(of: WorktreeRowDrop.contentTypes, delegate: WorktreeRowDropDelegate(
                rowHeight: rowHeight, allowsReordering: allowsReordering,
                isInFlight: worktree?.state.isInFlight ?? true,
                placement: $placement, onPaneTargeted: onPaneTargeted,
                onDrop: { payload, destination in
                    let result = payload.apply(repoID: repoID, targetWorktreeID: worktreeID, placement: destination,
                                  allowsReordering: allowsReordering, to: &appState)
                    // Invoke pane moves after releasing the state binding's writeback.
                    if case .movePane(let slot, let path) = result { onMovePane(slot, path) }
                }))
            .overlay(alignment: placement == .after ? .bottom : .top) {
                if placement != nil { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) }
            }
    }
}

/// The header remains a destination while the pinned section is collapsed.
struct PinnedWorktreeDropTarget: ViewModifier {
    let repoID: UUID
    @Binding var appState: AppState
    var isEnabled: Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(isTargeted && isEnabled ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .dropDestination(for: TransferableWorktreeMove.self) { payloads, _ in
                guard isEnabled, payloads.count == 1, let payload = payloads.first else { return false }
                return WorktreeDropReorder.pin(payload, repoID: repoID, to: &appState)
            } isTargeted: { isTargeted = $0 }
    }
}

extension View {
    func worktreeReorderTarget(
        repoID: RepoEntry.ID,
        worktreeID: WorktreeEntry.ID,
        appState: Binding<AppState>,
        isEnabled: Bool = true,
        onSelect: @escaping () -> Void,
        onMovePane: @escaping (PaneSlotID, String) -> Void,
        onPaneTargeted: @escaping (Bool) -> Void
    ) -> some View {
        modifier(WorktreeReorderTarget(
            repoID: repoID, worktreeID: worktreeID,
            appState: appState, isEnabled: isEnabled, onSelect: onSelect,
            onMovePane: onMovePane, onPaneTargeted: onPaneTargeted
        ))
    }
}
