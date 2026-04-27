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

    func testTeamModeOverridesUserCommand() {
        let decision = defaultCommandDecision(
            defaultCommand: "zsh",                       // user's stored value
            firstPaneOnly: false,
            isFirstPane: true,
            wasRehydrated: false,
            agentTeamsEnabled: true                      // new parameter
        )
        XCTAssertEqual(
            decision,
            .type("claude --dangerously-load-development-channels server:graftty-channel")
        )
    }

    func testTeamModeOffPreservesUserCommand() {
        let decision = defaultCommandDecision(
            defaultCommand: "zsh",
            firstPaneOnly: false,
            isFirstPane: true,
            wasRehydrated: false,
            agentTeamsEnabled: false
        )
        XCTAssertEqual(decision, .type("zsh"))
    }

    func testTeamModeStillSkipsRehydratedPanes() {
        let decision = defaultCommandDecision(
            defaultCommand: "zsh",
            firstPaneOnly: false,
            isFirstPane: true,
            wasRehydrated: true,                         // already running under zmx
            agentTeamsEnabled: true
        )
        XCTAssertEqual(decision, .skip)
    }
}
