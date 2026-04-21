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
}
