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

struct WorktreeReorderTarget: ViewModifier {
    let repoID: RepoEntry.ID
    let worktreeID: WorktreeEntry.ID
    @Binding var appState: AppState
    var isEnabled: Bool = true
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
            .draggable(TransferableWorktreeMove(repoID: repoID, worktreeID: worktreeID))
            .dropDestination(for: TransferableWorktreeMove.self) { items, location in
                guard isEnabled, let item = items.first else { return false }
                return WorktreeDropReorder.apply(
                    item,
                    targetWorktreeID: worktreeID,
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
        appState: Binding<AppState>,
        isEnabled: Bool = true
    ) -> some View {
        modifier(WorktreeReorderTarget(
            repoID: repoID,
            worktreeID: worktreeID,
            appState: appState, isEnabled: isEnabled
        ))
    }
}
