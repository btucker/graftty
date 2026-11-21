import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct CodexScrollbackTranscriptTests {
    @Test func keepsPromptsBeforeLargeToolResultsAndSeesLaterAppends() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = UUID().uuidString.lowercased()
        let file = directory.appendingPathComponent("rollout-\(session).jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(session)","cwd":"/repo/worktree"}}"#
        let prompt = #"{"timestamp":"2026-11-20T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"Earlier request"}}"#
        let largeTool = #"{"type":"response_item","payload":{"type":"function_call_output","output":"\#(String(repeating: "x", count: 5 * 1024 * 1024))"}}"#
        try Data(([header, prompt, largeTool].joined(separator: "\n") + "\n").utf8).write(to: file)
        let reader = CodexScrollbackTranscript(sessionID: session, worktree: "/repo/worktree", codexHome: home)
        #expect(reader.read()?.events.map(\.completed) == ["Earlier request"])
        let append = try FileHandle(forWritingTo: file)
        defer { try? append.close() }
        try append.seekToEnd()
        let next = prompt.replacingOccurrences(of: "Earlier request", with: "Next request")
            .replacingOccurrences(of: "01:00:00", with: "01:00:01")
        try append.write(contentsOf: Data(next.utf8))
        #expect(reader.read()?.events.map(\.completed) == ["Earlier request"])
        try append.write(contentsOf: Data("\n".utf8))
        #expect(reader.read()?.events.map(\.completed) == ["Earlier request", "Next request"])
    }

    @Test func readsASessionWhoseHeaderExceedsOneReadChunk() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = UUID().uuidString.lowercased()
        let file = directory.appendingPathComponent("rollout-\(session).jsonl")
        // Session metadata carries the provider's instructions, which can exceed 64 KiB.
        let instructions = String(repeating: "i", count: 100 * 1024)
        let header = #"{"type":"session_meta","payload":{"id":"\#(session)","cwd":"/repo/worktree","instructions":"\#(instructions)"}}"#
        let prompt = #"{"timestamp":"2026-11-20T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"Earlier request"}}"#
        try Data(([header, prompt].joined(separator: "\n") + "\n").utf8).write(to: file)
        let reader = CodexScrollbackTranscript(sessionID: session, worktree: "/repo/worktree", codexHome: home)
        #expect(reader.read()?.events.map(\.completed) == ["Earlier request"])
    }

    @Test func readsOnlyVisibleMessagesFromTheExactWorktreeThread() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("sessions/2026/11/20")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = UUID().uuidString.lowercased()
        let path = directory.appendingPathComponent("rollout-2026-11-20T00-00-00-\(session).jsonl")
        let transcript = """
        {"type":"session_meta","payload":{"id":"\(session)","cwd":"/repo/worktree"}}
        {"timestamp":"2026-11-20T01:00:00Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"message","content":[{"type":"text","text":"Find the missing section"},{"type":"image","image_url":"data:image/png,private"}]}}}
        {"timestamp":"2026-11-20T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Do not replay duplicated input"}]}}
        {"timestamp":"2026-11-20T01:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"analysis","content":[{"type":"output_text","text":"Do not expose hidden reasoning"}]}}
        {"timestamp":"2026-11-20T01:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final","content":[{"type":"output_text","text":"The section is ready."}]}}
        {"timestamp":"2026-11-20T01:00:04Z","type":"event_msg","payload":{"type":"user_message","message":"An incomplete write"}}
        """
        try transcript.write(to: path, atomically: true, encoding: .utf8)

        let timeline = try #require(CodexScrollbackTranscript.read(sessionID: session, worktree: "/repo/worktree", codexHome: home))
        #expect(timeline.events.map(\.completed) == ["Find the missing section", "The section is ready."])
        #expect(timeline.events.map(\.kind) == [.user, .agentResponse])
        #expect(CodexScrollbackTranscript.read(sessionID: session, worktree: "/repo/other", codexHome: home) == nil)
        #expect(CodexScrollbackTranscript.read(sessionID: UUID().uuidString, worktree: "/repo/worktree", codexHome: home) == nil)
    }
}
