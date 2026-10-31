import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec CONTEXT-49: When a harness supplies structured question replies, commands, review results, or interruptions, the application shall normalize them through harness-specific timeline plugins into shared presentation on Mac and mobile, retain surrounding human input, preserve unknown or malformed formats and literal examples, and restore structured content from saved history.")
struct HarnessTimelinePluginTests {
    private let reply = #"<send_user_message_question_reply>[{"question":"Which approach?","answer":"Design together first, then implement","questionItemId":"opaque-id"},{"question":"Targets?","answer":"Mac and mobile"}]</send_user_message_question_reply>"#

    @Test func codexRepliesRetainQuestionsAndAnswersWithoutTransportMetadata() throws {
        let part = try #require(WorktreePromptContent.parts(in: reply, runtime: "codex").first)
        #expect(part.source == .user)
        #expect(part.presentation?.kind == .questionReply)
        #expect(part.presentation?.items.map(\.label) == ["Which approach?", "Targets?"])
        #expect(part.presentation?.items.map(\.value) == ["Design together first, then implement", "Mac and mobile"])
        #expect(!part.text.contains("questionItemId"))
        var history = WorktreeHistory()
        history.record(.init(text: "Before.\n" + reply + "\nAfter.", at: .now, runtime: "codex"))
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        let events = WorktreeTimeline(history: restored, brief: nil).events
        #expect(events.map(\.completed) == ["Before.", part.text, "After."])
        #expect(events[1].presentation == part.presentation)
    }

    @Test func legacyRepliesAreReclassifiedDuringProjection() throws {
        var history = WorktreeHistory()
        history.record(.init(text: "placeholder", at: .now, runtime: "codex"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var inputs = try #require(object["inputs"] as? [[String: Any]])
        inputs[0]["text"] = reply
        inputs[0].removeValue(forKey: "parts")
        object["inputs"] = inputs
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(WorktreeTimeline(history: restored, brief: nil).events.first?.presentation?.kind == .questionReply)
    }

    @Test func malformedUnknownAndQuotedEnvelopesStayVisible() {
        for text in ["<send_user_message_question_reply>bad JSON</send_user_message_question_reply>",
                     #"<send_user_message_question_reply>[{"answer":"Missing question"}]</send_user_message_question_reply>"#,
                     "<send_user_message_question_reply>[]</send_user_message_question_reply>",
                     "<send_user_message_question_reply>truncated", "<future-format>Keep me</future-format>",
                     "Explain " + reply, "```xml\n" + reply + "\n```", "~~~xml\n" + reply + "\n~~~"] {
            #expect(WorktreePromptContent.parts(in: text, runtime: "codex") == [.init(source: .user, text: text)])
        }
        #expect(WorktreePromptContent.parts(in: reply, runtime: "future") == [.init(source: .user, text: reply)])
    }

    @Test func pluginsCanBeAddedWithoutChangingTheSharedParser() {
        struct ExamplePlugin: HarnessTimelinePlugin {
            let runtime = "example"
            let envelopeNames: Set<String> = ["example-input"]
            func parseEnvelope(name: String, header: String, body: String) -> WorktreePromptContent.Part? {
                .init(source: .user, text: body.uppercased())
            }
        }
        #expect(WorktreePromptContent.parts(in: "<example-input>hello</example-input>", runtime: "example",
            plugins: [ExamplePlugin()]) == [.init(source: .user, text: "HELLO")])
    }

    @Test func commandsAndInterruptionsAreSharedPresentation() {
        let shell = "<user_shell_command>\n<command>git status</command>\n<result>Exit code: 0</result>\n</user_shell_command>"
        let command = WorktreePromptContent.parts(in: shell, runtime: "codex").first
        #expect(command?.presentation?.kind == .command)
        #expect(command?.presentation?.items.first?.value == "git status")
        let slash = "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>fable</command-args>"
        let parts = WorktreePromptContent.parts(in: slash, runtime: "claude")
        #expect(parts.count == 1)
        #expect(parts.first?.presentation?.items.first?.value == "/model fable")
        #expect(WorktreePromptContent.parts(in: "[Request interrupted by user]", runtime: "claude").first?.presentation?.kind == .interruption)
        #expect(WorktreePromptContent.parts(in: "<turn_aborted>Interrupted</turn_aborted>", runtime: "codex").first?.source == .generated)
    }

    @Test func generatedHarnessContextDoesNotBecomeHumanInput() {
        let codex = "<hook_prompt>Report now</hook_prompt>\nKeep this.\n<guardian_tool_descriptions>Tool metadata</guardian_tool_descriptions>"
        #expect(WorktreePromptContent.parts(in: codex, runtime: "codex").map(\.text) == ["Keep this."])
        #expect(WorktreePromptContent.parts(in: "<local-command-caveat>Provider instruction</local-command-caveat>", runtime: "claude").isEmpty)
        #expect(WorktreePromptContent.parts(in: "This session is being continued from a previous conversation that ran out of context.\nSummary:\nPrevious work", runtime: "claude").isEmpty)
    }

    @Test func reviewsVoiceAndCommandOutputKeepTheirAuthorship() {
        let review = "<user_action><context>Review requested</context><action>review</action><results>No defects found.</results></user_action>"
        let part = WorktreePromptContent.parts(in: review, runtime: "codex").first
        #expect(part?.source == .generated)
        #expect(part?.presentation?.kind == .review)
        #expect(part?.text == "No defects found.")
        let voice = "<realtime_delegation><input>Keep this request.</input><transcript_delta>user: Keep this request.</transcript_delta></realtime_delegation>"
        #expect(WorktreePromptContent.parts(in: voice, runtime: "codex").map(\.text) == ["Keep this request."])
        let output = "<local-command-stdout>Model changed</local-command-stdout>"
        #expect(WorktreePromptContent.parts(in: output, runtime: "claude").first?.source == .generated)
        let peer = "<agent-message from=\"reviewer\">\n" + reply + "\n</agent-message>"
        #expect(WorktreePromptContent.parts(in: peer).allSatisfy { $0.source == .agent("reviewer") })
    }

    @Test func interruptionEndsTheRunningAgentTurn() {
        let start = Date()
        var history = WorktreeHistory()
        history.record(WorktreeHistory.AgentResponse(id: "before", text: "Working", at: start, runtime: "codex", sessionID: "session", isFinal: false))
        history.record(.init(text: "<turn_aborted>Interrupted</turn_aborted>", at: start.addingTimeInterval(1), runtime: "codex"))
        history.record(WorktreeHistory.AgentResponse(id: "after", text: "A later turn", at: start.addingTimeInterval(2), runtime: "codex", sessionID: "session", isFinal: true))
        let rows = WorktreeTimeline(history: history, brief: nil).rows(showAll: false)
        #expect(rows.map(\.events.count) == [1, 1, 1])
        #expect(rows.first?.isComplete == true)
    }

    @Test(arguments: ["agent_id", "agent_path"])
    func archivedCodexSubagentReportsKeepTheirSenderAndLiteralContent(senderKey: String) throws {
        let report = "Review complete.\n<task-notification>Literal example in report</task-notification>"
        let data = try JSONSerialization.data(withJSONObject: [senderKey: "reviewer", "status": ["completed": report]])
        let text = "<subagent_notification>\(String(decoding: data, as: UTF8.self))</subagent_notification>"
        #expect(WorktreePromptContent.parts(in: text, runtime: "codex") == [.init(source: .agent("reviewer"), text: report)])
    }

    @Test func archivedGeneratedContextAndSkillBodiesDoNotBecomeUserMessages() {
        #expect(WorktreePromptContent.parts(in: "<codex_internal_context source=\"goal\">Continue the existing task</codex_internal_context>", runtime: "codex").isEmpty)
        #expect(WorktreePromptContent.parts(in: "<recommended_plugins>Available apps</recommended_plugins>", runtime: "codex").isEmpty)
        let skill = "<skill>\n<name>code-review</name>\n<path>/skills/code-review/SKILL.md</path>\nLong skill instructions\n</skill>"
        let part = WorktreePromptContent.parts(in: skill, runtime: "codex").first
        #expect(part?.source == .generated)
        #expect(part?.presentation?.items.first?.value == "code-review")
        let legacyPeer = "<graftty-peer-messages trust=\"untrusted\">\nWorktree message from `/repo/reviewer`:\n\nReview complete.\n</graftty-peer-messages>"
        #expect(WorktreePromptContent.parts(in: legacyPeer).first?.source == .agent("/repo/reviewer"))
    }

    @Test func sessionNoticesKeepTheExistingSourceEncodingForOlderClients() throws {
        let input = WorktreeHistory.UserInput(text: "<turn_aborted>Interrupted</turn_aborted>", at: .now, runtime: "codex")
        #expect(input.source == .generated)
        var history = WorktreeHistory()
        history.record(input)
        let event = try #require(WorktreeTimeline(history: history, brief: nil).events.first)
        #expect(event.kind == .system)
        #expect(event.presentation?.kind == .interruption)
    }

    @Test func largeRepliesAreDecodedBeforeBoundingAndStayStructured() throws {
        let text = "<send_user_message_question_reply>" + String(data: try JSONSerialization.data(withJSONObject:
            [["question": "Which?", "answer": String(repeating: "👩🏽‍💻", count: 3000)]]), encoding: .utf8)! + "</send_user_message_question_reply>"
        let input = WorktreeHistory.UserInput(text: text, at: .now, runtime: "codex")
        var history = WorktreeHistory()
        history.record(input)
        let event = try #require(WorktreeTimeline(history: history, brief: nil).events.first)
        #expect(input.wasTruncated)
        #expect(input.text.utf8.count <= 8000)
        #expect(event.presentation?.kind == .questionReply)
        #expect(event.wasTruncated)
        #expect(event.presentation?.items.first?.label == "Which?")
        #expect(try JSONEncoder().encode(input).count < 40_000)
    }
}
