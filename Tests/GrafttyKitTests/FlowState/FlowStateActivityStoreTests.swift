import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateActivityStore")
struct FlowStateActivityStoreTests {
    @Test("@spec FLOW-4.3: When Flow State records activity, the application shall append durable activity rows and preserve per-worktree status-request cooldown timestamps.")
    func recordsActivityAndCooldowns() throws {
        let root = try temporaryDirectory()
        let store = FlowStateActivityStore(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 100)
        try store.append(.init(createdAt: now, kind: .publishError, message: "invalid enum", worktreeRef: nil))
        try store.recordStatusRequest(worktreeRef: "repo:feature", at: now)

        #expect(try store.recent(limit: 10).first?.message == "invalid enum")
        #expect(try store.lastStatusRequestAt(worktreeRef: "repo:feature") == now)

        let reopened = FlowStateActivityStore(rootDirectory: root)
        #expect(try reopened.recent(limit: 10).first?.kind == .publishError)
        #expect(try reopened.lastStatusRequestAt(worktreeRef: "repo:feature") == now)
    }

    @Test("@spec FLOW-4.14: Flow State activity reads shall ignore corrupt JSONL rows so one partial row does not erase recent valid activity.")
    func recentSkipsCorruptRows() throws {
        let root = try temporaryDirectory()
        let store = FlowStateActivityStore(rootDirectory: root)
        try store.append(.init(
            createdAt: Date(timeIntervalSince1970: 100),
            kind: .statusRequestSent,
            message: "first",
            worktreeRef: "repo:feature"
        ))
        let activityURL = root.appendingPathComponent("activity.jsonl", isDirectory: false)
        let handle = try FileHandle(forWritingTo: activityURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json}\n".utf8))
        try store.append(.init(
            createdAt: Date(timeIntervalSince1970: 101),
            kind: .statusRequestSent,
            message: "second",
            worktreeRef: "repo:feature"
        ))

        #expect(try store.recent(limit: 10).map(\.message) == ["second", "first"])
    }

    @Test("@spec FLOW-4.7: Flow State activity storage shall expose default root and default store constructors under the app state Flow State directory.")
    func defaultRootAndStoreUseAppStateFlowStateDirectory() {
        #expect(FlowStateActivityStore.defaultRoot().lastPathComponent == "flow-state")
        _ = FlowStateActivityStore.defaultStore()
    }
}
