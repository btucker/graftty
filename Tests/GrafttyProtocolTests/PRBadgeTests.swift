import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PRBadge")
struct PRBadgeTests {
    private let sampleURL = URL(string: "https://github.com/btucker/graftty/pull/42")!
    private let otherURL = URL(string: "https://github.com/btucker/graftty/pull/99")!

    @Test("@spec PR-3.2: While a worktree has a resolved PR/MR, the application shall display a forge-specific reference badge between the leading icon and branch label: `#<number>` for GitHub and `!<number>` for GitLab, with ungrouped decimal digits regardless of locale.")
    func referenceTextUsesForgePrefixAndUngroupedDigits() {
        let github = PRBadge(
            number: 5_000,
            state: .open,
            checks: .success,
            url: URL(string: "https://github.com/btucker/graftty/pull/5000")!
        )
        let selfHostedGitLab = PRBadge(
            number: 5_000,
            state: .open,
            checks: .success,
            url: URL(string: "https://gitlab.corp.example/team/graftty/-/merge_requests/5000")!
        )
        let githubRepoNamedMergeRequests = PRBadge(
            number: 5_000,
            state: .open,
            checks: .success,
            url: URL(string: "https://github.com/btucker/merge_requests/pull/5000")!
        )

        #expect(github.referenceText == "#5000")
        #expect(selfHostedGitLab.referenceText == "!5000")
        #expect(githubRepoNamedMergeRequests.referenceText == "#5000")
    }

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
