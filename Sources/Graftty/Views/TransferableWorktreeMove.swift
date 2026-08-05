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
    static let contentType = UTType(exportedAs: "com.graftty.sidebar-worktree-move")

    let repoID: RepoEntry.ID
    let worktreeID: WorktreeEntry.ID
    let parentFolderPath: String?

    init(
        repoID: RepoEntry.ID,
        worktreeID: WorktreeEntry.ID,
        parentFolderPath: String? = nil
    ) {
        self.repoID = repoID
        self.worktreeID = worktreeID
        self.parentFolderPath = parentFolderPath
    }

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
        targetParentFolderPath: String? = nil,
        placement: WorktreeDropPlacement,
        to appState: inout AppState
    ) -> Bool {
        guard payload.worktreeID != targetWorktreeID else { return false }
        guard payload.parentFolderPath == targetParentFolderPath else { return false }
        guard let repoIndex = appState.repos.firstIndex(where: { $0.id == payload.repoID }) else {
            return false
        }
        let worktrees = appState.repos[repoIndex].worktrees
        guard let sourceIndex = worktrees.firstIndex(where: { $0.id == payload.worktreeID }),
              let targetIndex = worktrees.firstIndex(where: { $0.id == targetWorktreeID })
        else {
            return false
        }

        let destination = placement == .before ? targetIndex : targetIndex + 1
        return applyListMove(
            inRepoID: payload.repoID,
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destination,
            to: &appState
        )
    }

    @discardableResult
    static func applyListMove(
        inRepoID repoID: RepoEntry.ID,
        fromOffsets: IndexSet,
        toOffset: Int,
        to appState: inout AppState
    ) -> Bool {
        guard !fromOffsets.isEmpty else { return false }
        guard let repoIndex = appState.repos.firstIndex(where: { $0.id == repoID }) else {
            return false
        }
        let worktrees = appState.repos[repoIndex].worktrees
        guard fromOffsets.allSatisfy({ worktrees.indices.contains($0) }) else { return false }
        guard toOffset >= 0, toOffset <= worktrees.count else { return false }

        let movingIDs = fromOffsets.map { worktrees[$0].id }
        guard movingIDs.allSatisfy({ id in
            worktrees.first(where: { $0.id == id })?.state.isInFlight == false
        }) else {
            return false
        }

        let neighborIndices = [toOffset - 1, toOffset]
            .filter { worktrees.indices.contains($0) && !fromOffsets.contains($0) }
        guard neighborIndices.allSatisfy({ !worktrees[$0].state.isInFlight }) else {
            return false
        }

        return appState.moveWorktrees(
            inRepoID: repoID,
            movingWorktreeIDs: movingIDs,
            toIndex: toOffset
        )
    }
}

struct WorktreeReorderTarget: ViewModifier {
    let repoID: RepoEntry.ID
    let worktreeID: WorktreeEntry.ID
    let parentFolderPath: String?
    @Binding var appState: AppState
    @State private var rowHeight: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            rowHeight = proxy.size.height
                        }
                        .onChange(of: proxy.size.height) { _, newHeight in
                            rowHeight = newHeight
                        }
                }
            }
            .draggable(TransferableWorktreeMove(
                repoID: repoID,
                worktreeID: worktreeID,
                parentFolderPath: parentFolderPath
            ))
            .dropDestination(for: TransferableWorktreeMove.self) { items, location in
                guard let item = items.first else { return false }
                return WorktreeDropReorder.apply(
                    item,
                    targetWorktreeID: worktreeID,
                    targetParentFolderPath: parentFolderPath,
                    placement: WorktreeDropPlacement.fromRowDropLocation(
                        location,
                        rowHeight: rowHeight
                    ),
                    to: &appState
                )
            }
    }
}

extension View {
    func worktreeReorderTarget(
        repoID: RepoEntry.ID,
        worktreeID: WorktreeEntry.ID,
        parentFolderPath: String? = nil,
        appState: Binding<AppState>
    ) -> some View {
        modifier(WorktreeReorderTarget(
            repoID: repoID,
            worktreeID: worktreeID,
            parentFolderPath: parentFolderPath,
            appState: appState
        ))
    }
}
