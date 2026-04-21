import Foundation
import Testing
@testable import GrafttyKit

@Suite("PRBadge")
struct PRBadgeTests {
    private let sampleURL = URL(string: "https://github.com/btucker/graftty/pull/42")!
    private let otherURL = URL(string: "https://github.com/btucker/graftty/pull/99")!

    @Test func equalWhenAllFieldsMatch() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, url: sampleURL)
        #expect(a == b)
    }

    @Test func inequalWhenNumberDiffers() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 43, state: .open, url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalWhenStateDiffers() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 42, state: .merged, url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalWhenURLDiffers() {
        let a = PRBadge(number: 42, state: .open, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, url: otherURL)
        #expect(a != b)
    }
}
