import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Drag-payload for moving a pane between worktrees in the sidebar
/// (PWD-1.4). In-app only — uses `.data` so we don't need a registered
/// UTType in the bundle Info.plist; SwiftUI's type-safe `Transferable`
/// matching keeps unrelated `Codable` Data drops from being decoded as
/// panes.
struct TransferableTerminalID: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
