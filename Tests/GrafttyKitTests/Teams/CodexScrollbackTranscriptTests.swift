import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct CodexScrollbackTranscriptTests {
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
