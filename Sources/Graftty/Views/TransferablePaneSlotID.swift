import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Drag-payload for moving a pane between worktrees in the sidebar
/// (PWD-1.4). In-app only — uses a pane-specific UTType so worktree
/// reorder drops and pane move drops never compete for the same generic
/// `public.data` provider.
struct TransferablePaneSlotID: Codable, Transferable {
    static let contentType = UTType(exportedAs: "com.graftty.sidebar-pane-slot-id")

    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
    }
}
