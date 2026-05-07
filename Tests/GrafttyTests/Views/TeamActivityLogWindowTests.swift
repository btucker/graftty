import XCTest
@testable import Graftty
@testable import GrafttyKit

final class TeamActivityLogViewModelTests: XCTestCase {
    /// @spec TEAM-7.3: While the Team Activity Log window is open for
    /// a team, the application shall display every `TeamInboxMessage`
    /// for that team in chronological order, refreshing live as new
    /// rows land in the inbox.
    @MainActor
    func testInitialEmptyThenObserverEmitsLoadsMessages() throws {
        let root = try Self.temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root)
        let viewModel = TeamActivityLogViewModel(
            rootDirectory: root,
            teamID: "t1",
            teamName: "team"
        )

        XCTAssertTrue(viewModel.messages.isEmpty)

        try inbox.appendMessage(
            teamID: "t1", teamName: "team", repoPath: "/r",
            from: TeamInboxEndpoint(member: "a", worktree: "/r", runtime: nil),
            to: TeamInboxEndpoint(member: "b", worktree: "/r/b", runtime: nil),
            priority: .normal, body: "hi"
        )

        viewModel.start()
        defer { viewModel.stop() }

        // Wait up to ~2s for the observer's main-queue hop to land.
        let deadline = Date().addingTimeInterval(2.0)
        while viewModel.messages.count < 1 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.body, "hi")
    }

    /// @spec TEAM-7.6: While the Team Activity Log window is open, the
    /// application shall expose a "Reveal in Finder" affordance whose
    /// target is the team's `messages.jsonl` file.
    @MainActor
    func testWindowExposesMessagesFileURLForReveal() throws {
        let root = try Self.temporaryDirectory()
        let window = TeamActivityLogWindow(
            rootDirectory: root,
            teamID: "team-7-6",
            teamName: "team-7-6"
        )
        let expected = TeamInbox.messagesURLFor(rootDirectory: root, teamID: "team-7-6")
        XCTAssertEqual(window.messagesFileURL, expected)
        XCTAssertEqual(window.messagesFileURL.lastPathComponent, "messages.jsonl")
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("activityLogVM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
