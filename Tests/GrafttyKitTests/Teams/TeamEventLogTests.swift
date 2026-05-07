import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamEventLog — observability append-only log")
struct TeamEventLogTests {

    @Test("agentStateTransition and zmxNudgeAttempt encode to JSON with stable shape.")
    func newEventKindsEncode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-eventlog-\(UUID().uuidString)")
        let log = TeamEventLog(rootDirectory: dir)
        try log.append(TeamEvent(
            teamID: "/r",
            kind: .agentStateTransition,
            detail: ["from": "active", "to": "idle", "runtime": "codex", "worktree": "/r/alice", "trigger": "stop"],
            timestamp: Date(timeIntervalSince1970: 1)
        ))
        try log.append(TeamEvent(
            teamID: "/r",
            kind: .zmxNudgeAttempt,
            detail: ["worktree": "/r/alice", "runtime": "codex", "outcome": "sent", "messageIDs": "id-1,id-2"],
            timestamp: Date(timeIntervalSince1970: 2)
        ))
        let url = dir.appendingPathComponent(TeamInbox.fileComponent("/r"), isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let text = try String(contentsOf: url)
        #expect(text.contains("\"kind\":\"agentStateTransition\""))
        #expect(text.contains("\"kind\":\"zmxNudgeAttempt\""))
    }

}
