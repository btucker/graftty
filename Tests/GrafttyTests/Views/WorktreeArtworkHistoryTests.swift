import Foundation
import GrafttyKit
import Testing
@testable import Graftty

@Suite("@spec LAYOUT-2.81: When deriving artwork context from agent history, the application shall use bounded recent user prompts from the latest top-level session registered to the exact worktree and first pane, excluding assistant output, tool results, and injected instructions.")
struct WorktreeArtworkHistoryTests {
    private let worktree = "/projects/example/.worktrees/art"
    private let session = "11111111-2222-3333-4444-555555555555"

    private func presence(runtime: TeamHookRuntime = .codex, pane: String = "first", path: String? = nil,
                          id: String? = nil, date: Double = 1, subagent: Bool = false) -> TeamPresenceRecord {
        TeamPresenceRecord(teamID: "team", worktree: path ?? worktree, runtime: runtime,
                           paneSessionName: pane, pid: 1, registeredAt: Date(timeIntervalSince1970: date),
                           runtimeSessionID: id ?? session, isSubagent: subagent)
    }

    private func withFixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = root.appendingPathComponent("sessions")
        let claude = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(codex, claude)
    }

    private func write(_ entries: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func metadata(path: String? = nil) -> [String: Any] {
        ["type": "session_meta", "payload": ["id": session, "cwd": path ?? worktree]]
    }

    private func user(_ text: String) -> [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": text]]]]
    }

    private func read(_ records: [TeamPresenceRecord], _ codex: URL, _ claude: URL) -> String? {
        WorktreeArtworkHistory.context(worktreePath: worktree, paneSessionName: "first", records: records,
                                      codexSessions: codex, claudeProjects: claude)
    }

    @Test func codexUsesUserPromptsAndSkipsInjectedMessages() throws {
        try withFixture { codex, claude in
            try write([metadata(), user("# AGENTS.md instructions for /projects\n<INSTRUCTIONS>rules</INSTRUCTIONS>"),
                       user("<environment_context>machine details</environment_context>"),
                       user("Graftty reply: command\n<graftty-peer-message>peer task</graftty-peer-message>"),
                       ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "assistant idea"]]]],
                       user("Build a telescope dashboard"),
                       ["type": "event_msg", "payload": ["type": "user_message", "message": "Build a telescope dashboard"]],
                       user("<system-reminder>private injected text</system-reminder>Show Saturn prominently")],
                      to: codex.appendingPathComponent("2026/09/16/rollout-date-\(session).jsonl"))
            #expect(read([presence()], codex, claude) == "Build a telescope dashboard\n\nShow Saturn prominently")
        }
    }

    @Test func claudeSkipsToolsMetaAndSidechains() throws {
        try withFixture { codex, claude in
            func message(_ content: Any, extra: [String: Any] = [:]) -> [String: Any] {
                var result: [String: Any] = ["type": "user", "sessionId": session, "cwd": worktree,
                                            "message": ["role": "user", "content": content]]
                result.merge(extra) { _, new in new }
                return result
            }
            try write([message("Create a lighthouse"), message("ignore metadata", extra: ["isMeta": true]),
                       message("ignore child", extra: ["isSidechain": true]),
                       message([["type": "tool_result", "content": "tool output"]]),
                       message([["type": "tool_result", "content": "tool output"], ["type": "text", "text": "injected tool guidance"]]),
                       message([["type": "text", "text": "Use a striped tower"]])],
                      to: claude.appendingPathComponent("-projects-example--worktrees-art/\(session).jsonl"))
            #expect(read([presence(runtime: .claude)], codex, claude) == "Create a lighthouse\n\nUse a striped tower")
        }
    }

    @Test func onlyExactPaneWorktreeAndLatestTopLevelSessionQualify() throws {
        try withFixture { codex, claude in
            try write([metadata(), user("A telescope")], to: codex.appendingPathComponent("rollout-\(session).jsonl"))
            #expect(read([presence(pane: "second"), presence(path: worktree + "-other")], codex, claude) == nil)
            #expect(read([presence(), presence(id: "child", date: 4, subagent: true)], codex, claude) == "A telescope")
            #expect(read([presence(), presence(id: "new-session", date: 3)], codex, claude) == nil)
        }
    }

    @Test func rejectsWrongMetadataMissingAndMalformedFiles() throws {
        try withFixture { codex, claude in
            let file = codex.appendingPathComponent("rollout-\(session).jsonl")
            #expect(read([presence()], codex, claude) == nil)
            try write([metadata(path: "/another/worktree"), user("Wrong project")], to: file)
            #expect(read([presence()], codex, claude) == nil)
            try write([["type": "session_meta", "payload": ["id": "different-session", "cwd": worktree]], user("Wrong session")], to: file)
            #expect(read([presence()], codex, claude) == nil)
            try "not json\n{\"broken\":".write(to: file, atomically: true, encoding: .utf8)
            #expect(read([presence()], codex, claude) == nil)
        }
    }

    @Test func usesOlderCodexEventsAndCapsRecentContext() throws {
        try withFixture { codex, claude in
            let events: [[String: Any]] = (0..<9).map {
                ["type": "event_msg", "payload": ["type": "user_message", "message": "Prompt \($0) " + String(repeating: "x", count: 900)]]
            }
            try write([metadata()] + events, to: codex.appendingPathComponent("rollout-\(session).jsonl"))
            let result = try #require(read([presence()], codex, claude))
            #expect(result.count <= 4_000)
            #expect(!result.contains("Prompt 3"))
            #expect(result.contains("Prompt 8"))
        }
    }

    @Test func boundedTailStillUsesHeaderIdentityAndRecentMessages() throws {
        try withFixture { codex, claude in
            let file = codex.appendingPathComponent("rollout-\(session).jsonl")
            try write([metadata(), user(String(repeating: "x", count: 1_200_000)), user("A recent observatory")], to: file)
            #expect(read([presence()], codex, claude) == "A recent observatory")
        }
    }

    @Test func followsManagedCodexSessionsDirectorySymlink() throws {
        try withFixture { codex, claude in
            try write([metadata(), user("A telescope dashboard")],
                      to: codex.appendingPathComponent("2026/09/16/rollout-\(session).jsonl"))
            let linkedSessions = codex.deletingLastPathComponent().appendingPathComponent("managed-sessions")
            try FileManager.default.createSymbolicLink(at: linkedSessions, withDestinationURL: codex)
            #expect(read([presence()], linkedSessions, claude) == "A telescope dashboard")
        }
    }
}
