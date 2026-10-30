import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec CONTEXT-48: When Claude provider input contains an agent-message envelope, the application shall display its content as an agent message with its available sender on Mac and mobile, including previously saved user inputs, while preserving surrounding human text and fenced examples.")
struct WorktreeSubagentMessageTests {
    private let message = "<agent-message from=\"code-review\">The review is complete.</agent-message>"

    @Test func newMessagesRetainAgentProvenanceAfterPersistence() throws {
        var history = WorktreeHistory()
        history.record(.init(text: message, at: .now, runtime: "claude"))
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        #expect(restored.inputs.first?.source == .agent("code-review"))
        let events = WorktreeTimeline(history: restored, brief: nil).events
        #expect(events.map(\.kind) == [.agentMessage])
        #expect(events.first?.title == "Message from code-review")
        #expect(events.first?.completed == "The review is complete.")
    }

    @Test(arguments: [false, true])
    func previouslySavedUserInputsRecoverTheirSender(hasSource: Bool) throws {
        var history = WorktreeHistory()
        history.record(.init(text: "Placeholder", at: .now, runtime: "claude"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var inputs = try #require(object["inputs"] as? [[String: Any]])
        inputs[0]["text"] = message
        if !hasSource { inputs[0].removeValue(forKey: "source") }
        object["inputs"] = inputs
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONSerialization.data(withJSONObject: object))
        let events = WorktreeTimeline(history: restored, brief: nil).events
        #expect(events.map(\.kind) == [.agentMessage])
        #expect(events.first?.title == "Message from code-review")
        #expect(events.first?.completed == "The review is complete.")
    }

    @Test func mixedInputsPreserveHumanTextAndSeparateAgentSenders() throws {
        let prompt = "Keep my request.\n\n" + message
            + "\n<agent-message from=\"test&amp;verify\">Tests passed.</agent-message>\nCheck mobile too."
        var history = WorktreeHistory()
        history.record(.init(text: prompt, at: .now, runtime: "claude"))
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        let events = WorktreeTimeline(history: restored, brief: nil).events
        #expect(events.map(\.kind) == [.user, .agentMessage, .agentMessage, .user])
        #expect(events.map(\.completed) == ["Keep my request.", "The review is complete.", "Tests passed.", "Check mobile too."])
        #expect(events.dropFirst(2).first?.title == "Message from test&verify")
    }

    @Test func missingSenderAndTruncatedEnvelopesRemainAgentMessages() {
        #expect(WorktreePromptContent.parts(in: "<agent-message>Still reviewing")
            == [.init(source: .agent(nil), text: "Still reviewing")])
        let body = String(repeating: "Review details. ", count: 300)
        var history = WorktreeHistory()
        history.record(.init(text: "<agent-message from=\"reviewer\">" + body + "</agent-message>", at: .now))
        #expect(history.inputs.first?.wasTruncated == true)
        let events = WorktreeTimeline(history: history, brief: nil).events
        #expect(events.map(\.kind) == [.agentMessage])
        #expect(events.first?.title == "Message from reviewer")
        #expect(events.first?.completed == String(body.prefix(2000)) + "…")
    }

    @Test func literalExamplesAndSimilarTagsRemainHumanInput() {
        for text in ["Explain <agent-message> in the docs.", "```xml\n" + message + "\n```",
                     "~~~xml\n" + message + "\n~~~", "<agent-message-example>Keep this.</agent-message-example>"] {
            #expect(WorktreePromptContent.parts(in: text) == [.init(source: .user, text: text)])
        }
    }

    @Test func fencedEnvelopeExamplesKeepOuterSenderAndFollowingSibling() throws {
        let body = "Review this example:\n```xml\n" + message + "\n```\nThe review is complete."
        var history = WorktreeHistory()
        history.record(.init(text: "<agent-message from=\"reviewer\">\n" + body
            + "\n</agent-message>\n" + message + "\nKeep my request.", at: .now))
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONEncoder().encode(history))
        let events = WorktreeTimeline(history: restored, brief: nil).events
        #expect(events.map(\.kind) == [.agentMessage, .agentMessage, .user])
        #expect(events.map(\.title) == ["Message from reviewer", "Message from code-review", "You sent a message"])
        #expect(events.map(\.completed) == [body, "The review is complete.", "Keep my request."])
    }

    @Test func nestedEnvelopesRetainSendersAndFollowingSibling() {
        let prompt = "<agent-message from=\"reviewer\">\nOuter review.\n" + message
            + "\nReview conclusion.\n</agent-message>\n" + message
        let parts = WorktreePromptContent.parts(in: prompt)
        #expect(parts.map(\.source) == [.agent("reviewer"), .agent("code-review"), .agent("reviewer"), .agent("code-review")])
        #expect(parts.map(\.text) == ["Outer review.", "The review is complete.", "Review conclusion.", "The review is complete."])
    }

    @Test(arguments: ["`", "~"])
    func shorterFencesCannotCloseLongerExamples(marker: String) {
        let outer = String(repeating: marker, count: 4)
        let inner = String(repeating: marker, count: 3)
        let example = outer + "markdown\n" + inner + "xml\nExample\n" + inner + "\n" + message + "\n" + outer
        #expect(WorktreePromptContent.parts(in: example) == [.init(source: .user, text: example)])
    }

    @Test func inlineOpeningTagMentionsDoNotConsumeFollowingHumanInput() {
        let body = "The <agent-message> tag needs documentation."
        let prompt = "<agent-message from=\"reviewer\">" + body + "</agent-message>\nKeep my request."
        #expect(WorktreePromptContent.parts(in: prompt) == [
            .init(source: .agent("reviewer"), text: body), .init(source: .user, text: "Keep my request.")])
    }

    @Test func adjacentNestedEnvelopesKeepTheOuterBoundary() {
        let prompt = "<agent-message from=\"reviewer\">" + message + message + "</agent-message>\nKeep my request."
        #expect(WorktreePromptContent.parts(in: prompt) == [
            .init(source: .agent("code-review"), text: "The review is complete."),
            .init(source: .agent("code-review"), text: "The review is complete."),
            .init(source: .user, text: "Keep my request.")])
    }

    @Test(arguments: [false, true])
    func unfinishedFencesDoNotConsumeFollowingHumanInput(hasNestedExample: Bool) {
        let body = "Example:\n```swift\n" + (hasNestedExample ? message : "let value = 1")
        let prompt = "<agent-message from=\"reviewer\">\n" + body + "\n</agent-message>\nKeep my request."
        #expect(WorktreePromptContent.parts(in: prompt) == [
            .init(source: .agent("reviewer"), text: body), .init(source: .user, text: "Keep my request.")])
    }

    @Test(arguments: ["`", "``"])
    func inlineCodeExamplesKeepAgentAttribution(delimiter: String) {
        let body = "Use " + delimiter + "<agent-message>example</agent-message>" + delimiter + " in the docs."
        let prompt = "<agent-message from=\"reviewer\">" + body + "</agent-message>\nKeep my request."
        #expect(WorktreePromptContent.parts(in: prompt) == [
            .init(source: .agent("reviewer"), text: body), .init(source: .user, text: "Keep my request.")])
    }

    @Test func unfinishedAgentFenceDoesNotConsumeHumanCodeExample() {
        let body = "Example:\n```swift\nlet value = 1"
        let request = "What about this?\n```swift\nlet other = 2\n```"
        let prompt = "<agent-message from=\"reviewer\">\n" + body + "\n</agent-message>\n" + request
        #expect(WorktreePromptContent.parts(in: prompt) == [
            .init(source: .agent("reviewer"), text: body), .init(source: .user, text: request)])
    }
}
