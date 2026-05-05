import Foundation

/// One renderable entry in the Team Activity Log. Wraps a resolved
/// `ActivityFeedRow` with the small annotations the view layer needs
/// to know about — namely whether it should collapse the header line
/// because the previous row had the same actor within the
/// continuation window.
struct RenderedFeedItem: Equatable, Identifiable {
    let id: String
    let row: ActivityFeedRow
    let isContinuation: Bool

    init(id: String, row: ActivityFeedRow, isContinuation: Bool = false) {
        self.id = id
        self.row = row
        self.isContinuation = isContinuation
    }
}
