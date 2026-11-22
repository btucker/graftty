import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("WorkspaceLayout Chat choice")
struct WorkspaceLayoutChatTests {
    private func layout() -> WorkspaceLayout<String> {
        var layout = WorkspaceLayout<String>()
        layout.addAgent("a")
        layout.addAgent("b")
        return layout
    }

    @Test func everyTabStartsInTerminal() {
        #expect(layout().showsChat("a") == false)
    }

    @Test func aChoiceIsRememberedPerTabAndSurvivesSaving() throws {
        var layout = layout()
        layout.setShowsChat(true, for: "a")
        #expect(layout.showsChat("a"))
        #expect(layout.showsChat("b") == false)

        let restored = try JSONDecoder().decode(
            WorkspaceLayout<String>.self, from: JSONEncoder().encode(layout)
        )
        #expect(restored.showsChat("a"))

        layout.setShowsChat(false, for: "a")
        #expect(layout.showsChat("a") == false)
    }

    @Test func choosingAViewChangesNoSelection() {
        var layout = layout()
        layout.select("b")
        let before = layout
        layout.setShowsChat(true, for: "a")

        #expect(layout.focusedSession == before.focusedSession)
        #expect(layout.groups.map(\.selected) == before.groups.map(\.selected))
        #expect(layout.lastAgent == before.lastAgent)
    }

    @Test func aClosedTabForgetsItsChoice() {
        var layout = layout()
        layout.setShowsChat(true, for: "a")
        layout.remove("a")
        layout.addAgent("a")
        #expect(layout.showsChat("a") == false)
    }

    @Test func aChoiceForAnUnknownTabIsIgnored() {
        var layout = layout()
        layout.setShowsChat(true, for: "zzz")
        #expect(layout.showsChat("zzz") == false)
    }

    @Test func aLayoutSavedBeforeChatStillLoads() throws {
        var saved = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(layout())
        ) as? [String: Any])
        saved["chatSessions"] = nil
        let restored = try JSONDecoder().decode(
            WorkspaceLayout<String>.self, from: JSONSerialization.data(withJSONObject: saved)
        )
        #expect(restored.sessions == ["a", "b"])
        #expect(restored.showsChat("a") == false)
    }
}
