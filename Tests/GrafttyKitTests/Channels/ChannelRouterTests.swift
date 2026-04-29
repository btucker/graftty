import XCTest
@testable import GrafttyKit

@MainActor
final class ChannelRouterTests: XCTestCase {
    var socketPath: String!

    override func setUp() async throws {
        socketPath = "/tmp/graftty-test-router-\(UUID().uuidString).sock"
    }
    override func tearDown() async throws { unlink(socketPath) }

    func testSubscriberReceivesInitialInstructions() async throws {
        let router = ChannelRouter(socketPath: socketPath, promptProvider: { _ in "hello prompt" })
        try router.start()
        defer { router.stop() }

        let client = try ChannelTestClient.connect(path: socketPath)
        try client.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)

        let line = try client.readLine(timeout: 2.0)
        XCTAssertTrue(line.contains("\"type\":\"instructions\""))
        XCTAssertTrue(line.contains("hello prompt"))
    }

    func testEventIsRoutedOnlyToMatchingWorktree() async throws {
        let router = ChannelRouter(socketPath: socketPath, promptProvider: { _ in "P" })
        try router.start()
        defer { router.stop() }

        let clientA = try ChannelTestClient.connect(path: socketPath)
        try clientA.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)
        _ = try clientA.readLine(timeout: 2.0)  // drain initial instructions

        let clientB = try ChannelTestClient.connect(path: socketPath)
        try clientB.send(#"{"type":"subscribe","worktree":"/wt/b","version":1}\#n"#)
        _ = try clientB.readLine(timeout: 2.0)

        try await Task.sleep(nanoseconds: 200_000_000)  // let subscriptions settle

        router.dispatch(
            worktreePath: "/wt/a",
            message: .event(type: "pr_state_changed", attrs: ["pr_number": "1"], body: "X")
        )

        let aReceived = try clientA.readLine(timeout: 2.0)
        XCTAssertTrue(aReceived.contains("pr_state_changed"))

        // B should NOT receive anything; expect read timeout.
        XCTAssertThrowsError(try clientB.readLine(timeout: 0.5))
    }

    func testPromptBroadcastReachesAllSubscribers() async throws {
        var currentPrompt = "P1"
        let router = ChannelRouter(socketPath: socketPath, promptProvider: { _ in currentPrompt })
        try router.start()
        defer { router.stop() }

        let c1 = try ChannelTestClient.connect(path: socketPath)
        try c1.send(#"{"type":"subscribe","worktree":"/wt/1","version":1}\#n"#)
        _ = try c1.readLine(timeout: 2.0)

        let c2 = try ChannelTestClient.connect(path: socketPath)
        try c2.send(#"{"type":"subscribe","worktree":"/wt/2","version":1}\#n"#)
        _ = try c2.readLine(timeout: 2.0)

        try await Task.sleep(nanoseconds: 200_000_000)

        currentPrompt = "P2"
        router.broadcastInstructions()

        let r1 = try c1.readLine(timeout: 2.0)
        let r2 = try c2.readLine(timeout: 2.0)
        XCTAssertTrue(r1.contains("P2"))
        XCTAssertTrue(r2.contains("P2"))
    }

    func testIsEnabledFalseSuppressesDispatch() async throws {
        let router = ChannelRouter(socketPath: socketPath, promptProvider: { _ in "P" })
        try router.start()
        defer { router.stop() }

        let c = try ChannelTestClient.connect(path: socketPath)
        try c.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)
        _ = try c.readLine(timeout: 2.0)

        try await Task.sleep(nanoseconds: 200_000_000)

        router.isEnabled = false
        router.dispatch(
            worktreePath: "/wt/a",
            message: .event(type: "pr_state_changed", attrs: [:], body: "X")
        )

        XCTAssertThrowsError(try c.readLine(timeout: 0.5))
    }
}
