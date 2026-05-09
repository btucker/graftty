import Testing
@testable import GrafttyKit

@Suite("""
@spec ATTN-1.21: When the CLI is invoked with an unknown subcommand at any level, the application shall append a `Did you mean '<closest>'?` suggestion to the error message whenever a registered subcommand name is within Levenshtein distance 2 of the input.
""")
struct SubcommandSuggestionsTests {
    @Test("Distance-1 typo finds match")
    func distanceOne() {
        #expect(SubcommandSuggestions.suggest("paen", from: ["pane", "team", "notify"]) == "pane")
        #expect(SubcommandSuggestions.suggest("shwo", from: ["show", "send", "list"]) == "show")
    }

    @Test("Distance-2 typo finds match")
    func distanceTwo() {
        // "pn" -> "pane" is 2 insertions ('a' and 'e'); a true distance-2 example.
        #expect(SubcommandSuggestions.suggest("pn", from: ["pane", "team"]) == "pane")
    }

    @Test("Distance-3+ returns nil")
    func tooFar() {
        #expect(SubcommandSuggestions.suggest("xyzzy", from: ["pane", "team"]) == nil)
    }

    @Test("Empty input or empty candidates returns nil")
    func emptyEdges() {
        #expect(SubcommandSuggestions.suggest("", from: ["pane"]) == nil)
        #expect(SubcommandSuggestions.suggest("pane", from: []) == nil)
    }

    @Test("Picks closest when multiple candidates within range")
    func picksClosest() {
        #expect(SubcommandSuggestions.suggest("send", from: ["sand", "show"]) == "sand")
    }
}
