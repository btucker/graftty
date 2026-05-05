import Foundation
import Testing
@testable import GrafttyKit

@Suite("PRBadge")
struct PRBadgeTests {
    private let sampleURL = URL(string: "https://github.com/btucker/graftty/pull/42")!
    private let otherURL = URL(string: "https://github.com/btucker/graftty/pull/99")!

    @Test func equalWhenAllFieldsMatch() {
        let a = PRBadge(number: 42, state: .open, checks: .success, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, checks: .success, url: sampleURL)
        #expect(a == b)
    }

    @Test func inequalWhenNumberDiffers() {
        let a = PRBadge(number: 42, state: .open, checks: .success, url: sampleURL)
        let b = PRBadge(number: 43, state: .open, checks: .success, url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalWhenStateDiffers() {
        let a = PRBadge(number: 42, state: .open, checks: .success, url: sampleURL)
        let b = PRBadge(number: 42, state: .merged, checks: .success, url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalWhenChecksDiffer() {
        let a = PRBadge(number: 42, state: .open, checks: .success, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, checks: .failure, url: sampleURL)
        #expect(a != b)
    }

    @Test func inequalWhenURLDiffers() {
        let a = PRBadge(number: 42, state: .open, checks: .success, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, checks: .success, url: otherURL)
        #expect(a != b)
    }

    @Test func inequalWhenMergeableDiffers() {
        let a = PRBadge(number: 42, state: .open, checks: .success, mergeable: .mergeable, url: sampleURL)
        let b = PRBadge(number: 42, state: .open, checks: .success, mergeable: .conflicting, url: sampleURL)
        #expect(a != b)
    }
}
