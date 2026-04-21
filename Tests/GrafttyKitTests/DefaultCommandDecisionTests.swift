import XCTest
@testable import GrafttyKit

final class DefaultCommandDecisionTests: XCTestCase {
    func testEmptyCommandSkips() {
        let decision = defaultCommandDecision(
            defaultCommand: "",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }

    func testEmptyCommandSkipsEvenWhenRehydratedFalseAndFirstPaneFalse() {
        let decision = defaultCommandDecision(
            defaultCommand: "",
            firstPaneOnly: false,
            isFirstPane: false,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }

    func testRehydratedPaneSkipsRegardlessOfOtherInputs() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: true
        )
        XCTAssertEqual(decision, .skip)
    }

    func testFirstPaneTypesCommand() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .type("claude"))
    }

    func testNonFirstPaneSkipsWhenFirstPaneOnlyIsTrue() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: false,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }

    func testNonFirstPaneTypesCommandWhenFirstPaneOnlyIsFalse() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: false,
            isFirstPane: false,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .type("claude"))
    }

    func testFirstPaneTypesCommandWhenFirstPaneOnlyIsFalse() {
        let decision = defaultCommandDecision(
            defaultCommand: "npm run dev",
            firstPaneOnly: false,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .type("npm run dev"))
    }

    func testWhitespaceOnlyCommandSkips() {
        let decision = defaultCommandDecision(
            defaultCommand: "   ",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .skip)
    }

    func testChannelsEnabledInsertsFlagsAfterClaudeBinaryName() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: true
        )
        XCTAssertEqual(decision, .type(
            "claude --channels plugin:graftty-channel --dangerously-load-development-channels plugin:graftty-channel"
        ))
    }

    func testChannelsEnabledWithExistingArgsInsertsFlagsBeforeArgs() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude --model opus",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: true
        )
        XCTAssertEqual(decision, .type(
            "claude --channels plugin:graftty-channel --dangerously-load-development-channels plugin:graftty-channel --model opus"
        ))
    }

    func testChannelsEnabledForNonClaudeCommandLeavesUnchanged() {
        let decision = defaultCommandDecision(
            defaultCommand: "zsh",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: true
        )
        XCTAssertEqual(decision, .type("zsh"))
    }

    func testChannelsDisabledLeavesCommandUnchanged() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: false
        )
        XCTAssertEqual(decision, .type("claude"))
    }

    func testChannelsEnabledDoesNotMatchClaudeInLargerWord() {
        // "claudex" shouldn't match "claude" — we do token matching, not prefix.
        let decision = defaultCommandDecision(
            defaultCommand: "claudex",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: true
        )
        XCTAssertEqual(decision, .type("claudex"))
    }

    func testChannelsEnabledDefaultArgumentIsFalse() {
        // Existing callsites (no channelsEnabled:) must keep old behavior.
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false
        )
        XCTAssertEqual(decision, .type("claude"))
    }
}
