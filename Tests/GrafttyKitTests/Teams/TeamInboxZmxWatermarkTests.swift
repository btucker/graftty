import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamInbox.zmxWatermark — per-(team,worktree,runtime) read state for zmx delivery")
struct TeamInboxZmxWatermarkTests {
    @Test("Initial read returns nil for unknown key.")
    func initialNil() throws {
        let inbox = try Self.makeInbox()
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex") == nil)
    }

    @Test("Advance writes and read returns the most recent ID.")
    func advanceThenRead() throws {
        let inbox = try Self.makeInbox()
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex", to: "msg-7")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex") == "msg-7")
    }

    @Test("Watermarks are independent per (worktree, runtime).")
    func independentKeys() throws {
        let inbox = try Self.makeInbox()
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex", to: "a-1")
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/bob", runtime: "claude", to: "b-1")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex") == "a-1")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/bob", runtime: "claude") == "b-1")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "claude") == nil)
    }

    @Test("Advancing twice replaces the prior value (latest write wins).")
    func advanceOverwritesPriorValue() throws {
        let inbox = try Self.makeInbox()
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex", to: "msg-1")
        try inbox.advanceZmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex", to: "msg-2")
        #expect(try inbox.zmxWatermark(teamID: "/r", worktree: "/r/alice", runtime: "codex") == "msg-2")
    }

    private static func makeInbox() throws -> TeamInbox {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-zmx-watermark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return TeamInbox(rootDirectory: dir, idGenerator: { UUID().uuidString }, now: { Date() })
    }
}
