import Testing
import Foundation
@testable import GrafttyKit

@Suite("TeamEventLog — append-only events.jsonl")
struct TeamEventLogTests {
    @Test("Appending events produces one JSON object per line.")
    func appendsLines() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = TeamEventLog(rootDirectory: dir)
        try log.append(.init(teamID: "team-x", kind: .registered, detail: ["worktree": "wt-foo", "runtime": "claude"]))
        try log.append(.init(teamID: "team-x", kind: .nudgeSent, detail: ["worktree": "wt-foo", "messages": "1"]))

        let path = dir.appendingPathComponent("team-x").appendingPathComponent("events.jsonl")
        let contents = try String(contentsOf: path)
        let lines = contents.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)

        // Each line is valid JSON.
        for line in lines {
            _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
        }
    }

    @Test("Concurrent appends to the same log do not corrupt lines.")
    func concurrentAppendsSafe() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = TeamEventLog(rootDirectory: dir)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try? log.append(.init(teamID: "team-x", kind: .nudgeSent, detail: ["i": "\(i)"]))
                }
            }
        }

        let path = dir.appendingPathComponent("team-x").appendingPathComponent("events.jsonl")
        let contents = try String(contentsOf: path)
        let lines = contents.split(separator: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 50)
        for line in lines {
            _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
        }
    }
}
