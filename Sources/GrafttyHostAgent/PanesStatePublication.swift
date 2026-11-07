import Foundation
import GrafttyProtocol

/// One immutable snapshot and its wire representation, shared by subscribers
/// to the same projection. Authentication and channel lifetimes stay separate.
public final class PanesStatePublication: Sendable {
    public let message: PanesStateMessage
    public let encoded: Data?

    public init(_ message: PanesStateMessage) {
        self.message = message
        encoded = try? JSONEncoder().encode(message)
    }

    public static func snapshot(_ worktrees: [WorktreePanes], sidebar: SidebarSnapshot? = nil) -> PanesStatePublication {
        .init(.snapshot(worktrees, sidebar: sidebar))
    }
}
