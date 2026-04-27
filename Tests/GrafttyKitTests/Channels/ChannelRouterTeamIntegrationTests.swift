import XCTest
@testable import GrafttyKit

@MainActor
final class ChannelRouterTeamIntegrationTests: XCTestCase {

    private var socketPath: String!

    override func setUp() async throws {
        socketPath = "/tmp/graftty-channel-test-\(UUID().uuidString).sock"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testProviderReceivesPerWorktreeContext() async throws {
        // The prompt provider closure runs on the channel-server's I/O thread.
        // Use a thread-safe accumulator so the assertion thread can read what
        // the I/O thread wrote.
        let recorder = CallRecorder()
        let router = ChannelRouter(
            socketPath: socketPath,
            promptProvider: { wt in
                recorder.append(wt)
                return "prompt-for-wt1"  // no slashes — avoids JSON escape concerns
            }
        )
        try router.start()
        defer { router.stop() }

        // Subscribe and synchronously wait for the initial instructions line.
        // Receiving the line proves the server ran the prompt provider for
        // that subscriber, which is what the test asserts. No timing-based
        // sleep is needed.
        let client1 = try ChannelTestClient.connect(path: socketPath)
        try client1.send(#"{"type":"subscribe","worktree":"/r/a","version":1}\#n"#)
        _ = try client1.readLine(timeout: 2.0)

        let client2 = try ChannelTestClient.connect(path: socketPath)
        try client2.send(#"{"type":"subscribe","worktree":"/r/b","version":1}\#n"#)
        _ = try client2.readLine(timeout: 2.0)

        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.contains("/r/a"), "calls=\(snapshot)")
        XCTAssertTrue(snapshot.contains("/r/b"), "calls=\(snapshot)")
    }

    func testInitialInstructionsContainWorktreePath() async throws {
        let router = ChannelRouter(
            socketPath: socketPath,
            // Use a prompt that doesn't contain "/" so JSON encoding doesn't
            // escape slashes, making assertions straightforward.
            promptProvider: { wt in "prompt-for-wt1" }
        )
        try router.start()
        defer { router.stop() }

        let client = try ChannelTestClient.connect(path: socketPath)
        try client.send(#"{"type":"subscribe","worktree":"/r/wt1","version":1}\#n"#)

        let line = try client.readLine(timeout: 2.0)
        XCTAssertTrue(line.contains("\"type\":\"instructions\""))
        XCTAssertTrue(line.contains("prompt-for-wt1"))
    }

    /// Lock-guarded accumulator. NSLock isn't usable directly from async
    /// contexts in Swift 6, so we wrap the lock usage in synchronous methods
    /// the test can call before/after the await points without lifetime issues.
    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            values.append(s)
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    func testBroadcastInstructionsRendersPerSubscriber() async throws {
        // Use worktree identifiers that don't contain "/" to avoid JSON
        // slash-escaping in raw string comparisons.
        let router = ChannelRouter(
            socketPath: socketPath,
            promptProvider: { wt in "body-\(wt.replacingOccurrences(of: "/", with: "-"))" }
        )
        try router.start()
        defer { router.stop() }

        let c1 = try ChannelTestClient.connect(path: socketPath)
        try c1.send(#"{"type":"subscribe","worktree":"/r/a","version":1}\#n"#)
        _ = try c1.readLine(timeout: 2.0)  // drain initial instructions

        let c2 = try ChannelTestClient.connect(path: socketPath)
        try c2.send(#"{"type":"subscribe","worktree":"/r/b","version":1}\#n"#)
        _ = try c2.readLine(timeout: 2.0)

        // The initial instructions line is enqueued by the server's I/O
        // thread. Even after the test's readLine returns the bytes, the
        // socket-server's internal subscriber list may not yet reflect both
        // clients (registration commits after the write side completes).
        // Yield briefly so the registration has settled before we broadcast.
        try await Task.sleep(nanoseconds: 200_000_000)

        router.broadcastInstructions()

        let r1 = try c1.readLine(timeout: 2.0)
        let r2 = try c2.readLine(timeout: 2.0)
        XCTAssertTrue(r1.contains("body--r-a"), "c1 got: \(r1)")
        XCTAssertTrue(r2.contains("body--r-b"), "c2 got: \(r2)")
    }
}
