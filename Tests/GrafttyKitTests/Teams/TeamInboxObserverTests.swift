import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec TEAM-7.4: When the messages.jsonl file appended-to is the team's inbox, the application shall emit the parsed message list to the registered observer callback within one second of the append, including when the file is created after the observer started watching.")
struct TeamInboxObserverTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inboxObserverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func emitsOnAppend() async throws {
        let root = try Self.temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root)
        let teamID = "team-1"
        let observer = TeamInboxObserver(rootDirectory: root, teamID: teamID)
        actor Capture {
            var emitted: [[TeamInboxMessage]] = []
            func record(_ messages: [TeamInboxMessage]) { emitted.append(messages) }
            func count() -> Int { emitted.count }
            func last() -> [TeamInboxMessage]? { emitted.last }
        }
        let capture = Capture()
        let cancellable = observer.start { messages in
            Task { await capture.record(messages) }
        }
        defer { cancellable.cancel() }

        try inbox.appendMessage(
            teamID: teamID, teamName: "t", repoPath: "/r",
            from: TeamInboxEndpoint(member: "a", worktree: "/r", runtime: nil),
            to: TeamInboxEndpoint(member: "b", worktree: "/r/x", runtime: nil),
            priority: .normal, body: "hi"
        )

        // The first emit may be the empty initial-state snapshot;
        // wait until the post-append emit lands (a non-empty list).
        let deadline = Date().addingTimeInterval(2.0)
        while await (capture.last()?.count ?? 0) < 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await capture.count() >= 1)
        #expect(await capture.last()?.count == 1)
    }

    @Test func emitsAfterFileCreatedLate() async throws {
        let root = try Self.temporaryDirectory()
        let teamID = "team-2"
        let observer = TeamInboxObserver(rootDirectory: root, teamID: teamID)
        actor Capture {
            var emitted: [[TeamInboxMessage]] = []
            func record(_ messages: [TeamInboxMessage]) { emitted.append(messages) }
            func last() -> [TeamInboxMessage]? { emitted.last }
        }
        let capture = Capture()
        let cancellable = observer.start { messages in
            Task { await capture.record(messages) }
        }
        defer { cancellable.cancel() }

        // File doesn't exist yet; sleep a beat then create it via the
        // first append. The observer is expected to reattach on the
        // parent-dir `.write` event and emit the new row.
        try await Task.sleep(nanoseconds: 100_000_000)

        let inbox = TeamInbox(rootDirectory: root)
        try inbox.appendMessage(
            teamID: teamID, teamName: "t", repoPath: "/r",
            from: TeamInboxEndpoint(member: "a", worktree: "/r", runtime: nil),
            to: TeamInboxEndpoint(member: "b", worktree: "/r/x", runtime: nil),
            priority: .normal, body: "late"
        )

        let deadline = Date().addingTimeInterval(2.0)
        while await capture.last()?.count != 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(await capture.last()?.count == 1)
    }
}
