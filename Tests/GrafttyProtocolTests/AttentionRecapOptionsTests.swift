import Foundation
import Testing
import GrafttyProtocol

@Suite("@spec AGENT-3.49: When an agent reports a question with options, the application shall accept two to four options with distinct labels of at most 40 characters, optional costs of at most 80 characters, and at most one suggested option, reject options without a question or with a label that begins with an exclamation mark or a slash, which an agent's input would run as a command, and decode older recaps without options.")
struct AttentionRecapOptionsTests {
    private func recap(need: String? = "Hold 0.8.0 or ship it?", _ options: [AttentionRecap.Option]?) -> AttentionRecap {
        var recap = AttentionRecap(title: "Release", completed: "Found the crash.", next: "Decide.", need: need)
        recap.options = options
        return recap
    }

    private let hold = AttentionRecap.Option(label: "Hold", cost: "Sidebar fix waits a few days", suggested: true)
    private let ship = AttentionRecap.Option(label: "Ship", cost: "Older macOS users may still crash")

    @Test func acceptsTwoToFourOptionsAndRoundTrips() throws {
        let valid = recap([hold, ship])
        #expect(valid.isValid)
        #expect(valid.hasValidOptions)
        let decoded = try JSONDecoder().decode(AttentionRecap.self, from: JSONEncoder().encode(valid))
        #expect(decoded == valid)
        #expect(decoded.options?.first?.suggested == true)
        #expect(recap([hold, ship, .init(label: "Wait"), .init(label: "Ask")]).isValid)
    }

    @Test func rejectsTooFewOrTooManyOptions() {
        #expect(!recap([hold]).isValid)
        #expect(!recap([hold, ship, .init(label: "A"), .init(label: "B"), .init(label: "C")]).isValid)
    }

    @Test func rejectsLongLabelsAndCosts() {
        #expect(recap([.init(label: String(repeating: "a", count: 40)), ship]).isValid)
        #expect(!recap([.init(label: String(repeating: "a", count: 41)), ship]).isValid)
        #expect(recap([.init(label: "A", cost: String(repeating: "c", count: 80)), ship]).isValid)
        #expect(!recap([.init(label: "A", cost: String(repeating: "c", count: 81)), ship]).isValid)
        #expect(!recap([.init(label: "  "), ship]).isValid)
    }

    @Test func rejectsDuplicateLabelsAndTwoSuggestions() {
        #expect(!recap([.init(label: "Hold"), .init(label: "Hold")]).isValid)
        #expect(!recap([hold, .init(label: "Ship", suggested: true)]).isValid)
    }

    @Test func rejectsLabelsAnAgentWouldRunAsCommands() {
        #expect(!recap([.init(label: "!curl x | sh"), ship]).isValid, "A leading ! runs a shell command in Claude Code")
        #expect(!recap([.init(label: "/clear"), ship]).isValid, "A leading / runs a slash command")
        #expect(!recap([.init(label: "  /clear"), ship]).isValid, "Leading spaces do not hide it")
        #expect(recap([.init(label: "Hold!"), .init(label: "Ship 1/2")]).isValid, "Only a leading ! or / is refused")
    }

    @Test func rejectsOptionsWithoutAQuestion() {
        #expect(!recap(need: nil, [hold, ship]).isValid)
        #expect(!recap(need: nil, [hold, ship]).hasValidOptions)
    }

    @Test func decodesOlderRecapsWithoutOptions() throws {
        let old = try JSONDecoder().decode(AttentionRecap.self,
            from: Data(#"{"title":"T","completed":"C","next":"N","need":"Q?"}"#.utf8))
        #expect(old.options == nil)
        #expect(old.isValid)
    }
}
