import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec CONTEXT-45: When provider input contains background task notifications, the application shall omit those generated envelopes from the Mac and mobile timeline, including previously saved user inputs, while preserving surrounding human text and fenced examples.")
struct WorktreePromptContentTests {
    private let notification = """
    <task-notification>
    <task-id>background-task</task-id>
    <tool-use-id>toolu_example</tool-use-id>
    <output-file>/private/tmp/task.output</output-file>
    <status>completed</status>
    <summary>Background command completed (exit code 0)</summary>
    </task-notification>
    """

    @Test func newNotificationsAreGeneratedAndDoNotEnterTheTimeline() {
        let notices = notification + "\n\n" + notification
        #expect(WorktreePromptContent.parts(in: notices).isEmpty)
        var history = WorktreeHistory()
        history.record(.init(text: notices, at: .now, runtime: "claude"))
        #expect(history.inputs.first?.source == .generated)
        #expect(WorktreeTimeline(history: history, brief: nil).events.isEmpty)
    }

    @Test(arguments: [false, true])
    func previouslySavedNotificationsAreHidden(hasSource: Bool) throws {
        var history = WorktreeHistory()
        history.record(.init(text: "Placeholder", at: .now, runtime: "claude"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var inputs = try #require(object["inputs"] as? [[String: Any]])
        inputs[0]["text"] = notification + "\n\n" + notification
        if !hasSource { inputs[0].removeValue(forKey: "source") }
        object["inputs"] = inputs
        let restored = try JSONDecoder().decode(WorktreeHistory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(WorktreeTimeline(history: restored, brief: nil).events.isEmpty)
    }

    @Test func surroundingRequestsSurviveAndTruncatedNotificationsStayHidden() {
        let text = "Keep the first request.\n\n" + notification + "\n\nKeep the next request."
        #expect(WorktreePromptContent.parts(in: text).map(\.text) == ["Keep the first request.", "Keep the next request."])
        var history = WorktreeHistory()
        history.record(.init(text: text, at: .now))
        #expect(WorktreeTimeline(history: history, brief: nil).events.map(\.completed) == ["Keep the first request.\n\nKeep the next request."])
        #expect(WorktreePromptContent.parts(in: "<task-notification>\n<summary>Still running").isEmpty)
    }

    @Test func literalExamplesAndSimilarTagNamesRemainHumanInput() {
        for text in ["Explain <task-notification> in the docs.", "```xml\n" + notification + "\n```",
                     "<task-notification-example>Keep this example.</task-notification-example>"] {
            #expect(WorktreePromptContent.parts(in: text) == [.init(source: .user, text: text)])
        }
    }
}
