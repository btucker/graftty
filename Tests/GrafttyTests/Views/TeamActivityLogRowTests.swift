import XCTest
import SwiftUI
@testable import Graftty
@testable import GrafttyKit

/// The pure variant-resolution mapping is exercised by the
/// Swift Testing suite at `ActivityFeedRowTests`. This file keeps a
/// thin XCTest fixture asserting that `TeamActivityLogRow` accepts a
/// `RenderedFeedItem` for every `ActivityFeedRow` case without
/// crashing or rejecting any case at the SwiftUI body boundary.
final class TeamActivityLogRowTests: XCTestCase {
    @MainActor
    func testRowRendersEveryVariant() {
        let cases: [ActivityFeedRow] = [
            .chat(
                worktree: "alice", recipient: "bob",
                body: "hi", timestamp: Date(), isUrgent: false
            ),
            .chat(
                worktree: "alice", recipient: nil,
                body: "self note", timestamp: Date(), isUrgent: true
            ),
            .system(
                worktree: "codex-hooks", iconName: "circle.fill",
                body: "PR #1234 went open → ready_for_review",
                timestamp: Date()
            ),
            .memberJoined(worktree: "carol"),
            .memberLeft(worktree: "carol"),
            .dayDivider(label: "TODAY"),
        ]

        for row in cases {
            let item = RenderedFeedItem(id: "test", row: row, isContinuation: false)
            // Hosting the SwiftUI view in an NSHostingController forces
            // body evaluation, surfacing any crash/precondition.
            let view = TeamActivityLogRow(item: item)
            let host = NSHostingController(rootView: view)
            XCTAssertNotNil(host.view, "row should render: \(row)")
        }
    }
}
