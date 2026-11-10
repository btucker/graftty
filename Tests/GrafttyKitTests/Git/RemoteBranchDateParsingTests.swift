import Testing
import Foundation
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("RemoteBranchDateParsing")
struct RemoteBranchDateParsingTests {
    @Test(arguments: ["", "not-a-date", "1778434200junk", "1.5", "1e9", "nan", "inf", "9223372036854775808"])
    func invalidOrAbsentTimestampRetainsBranchWithDistantPast(_ timestamp: String) {
        let snapshot = RemoteBranchStore.parseCombinedRefs("""
        refs/heads/feature/local\t\(timestamp)\trefs/remotes/origin/feature/remote\t
        refs/remotes/origin/feature/remote\t\(timestamp)\t\t
        """)

        #expect(snapshot.localBranches == [BranchRef(name: "feature/local", lastCommitDate: .distantPast)])
        #expect(snapshot.remoteBranches == [BranchRef(name: "feature/remote", lastCommitDate: .distantPast)])
        #expect(snapshot.upstreams == ["feature/local": "feature/remote"])
    }

    @Test(arguments: [Int64(-2_208_988_800), -1, 0, 1, 1_778_434_200, 253_402_300_799])
    func parsesSignedIntegerSeconds(_ timestamp: Int64) {
        let snapshot = RemoteBranchStore.parseCombinedRefs("refs/heads/history\t\(timestamp)\t\t\n")
        #expect(snapshot.localBranches == [
            BranchRef(name: "history", lastCommitDate: Date(timeIntervalSince1970: Double(timestamp))),
        ])
    }

    @Test func ignoresIncompleteRowsAndUnrelatedRefs() {
        let snapshot = RemoteBranchStore.parseCombinedRefs("""
        refs/heads/missing-columns\t0
        refs/heads/missing-symref\t0\t
        refs/remotes/upstream/main\t0\t\t
        refs/remotes/origin-extra/main\t0\t\t
        refs/tags/v1\t0\t\t
        refs/heads/(detached)\t0\t\t
        refs/heads/ \t0\t\t
        refs/remotes/origin/\t0\t\t
        refs/heads/main\t0\trefs/remotes/upstream/main\t
        refs/remotes/origin/HEAD\t\t\trefs/remotes/origin/release/stable
        """)

        #expect(snapshot.localBranches == [BranchRef(name: "main", lastCommitDate: Date(timeIntervalSince1970: 0))])
        #expect(snapshot.remoteBranches.isEmpty)
        #expect(snapshot.upstreams.isEmpty)
        #expect(snapshot.defaultBranch == "release/stable")
    }

    @Test func defaultListReadsRealGitDatesAndBranchMetadata() async throws {
        let repo = try makeTempDir(prefix: "branch-dates")
        defer { try? FileManager.default.removeItem(at: repo) }
        // Raw Git dates give different local times for the same instant.
        // Epoch zero and 1980 cover historical dates accepted by Git.
        try #require(try shellInRepo("""
            git init -b main &&
            GIT_AUTHOR_DATE='1778434200 -0500' GIT_COMMITTER_DATE='1778434200 -0500' git commit --allow-empty -m first &&
            git update-ref refs/remotes/origin/release/stable HEAD &&
            git remote add origin https://example.invalid/fixture.git &&
            git config branch.main.remote origin &&
            git config branch.main.merge refs/heads/release/stable &&
            git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release/stable &&
            git checkout -b feature/same-instant &&
            GIT_AUTHOR_DATE='1778434200 +0930' GIT_COMMITTER_DATE='1778434200 +0930' git commit --allow-empty -m same &&
            git update-ref refs/remotes/origin/feature/same-instant HEAD &&
            git checkout -b history/epoch &&
            GIT_AUTHOR_DATE='@0 +0000' GIT_COMMITTER_DATE='@0 +0000' git commit --allow-empty -m epoch &&
            git checkout -b history/1980 &&
            GIT_AUTHOR_DATE='315532800 +0545' GIT_COMMITTER_DATE='315532800 +0545' git commit --allow-empty -m historical &&
            git update-ref refs/remotes/upstream/ignored HEAD &&
            git update-ref refs/remotes/origin-extra/ignored HEAD &&
            git tag ignored
            """, at: repo) == 0)

        let snapshot = try await RemoteBranchStore.defaultList(repo.path)
        let sameInstant = Date(timeIntervalSince1970: 1_778_434_200)
        #expect(Set(snapshot.localBranches) == [
            BranchRef(name: "main", lastCommitDate: sameInstant),
            BranchRef(name: "feature/same-instant", lastCommitDate: sameInstant),
            BranchRef(name: "history/epoch", lastCommitDate: Date(timeIntervalSince1970: 0)),
            BranchRef(name: "history/1980", lastCommitDate: Date(timeIntervalSince1970: 315_532_800)),
        ])
        #expect(Set(snapshot.remoteBranches) == [
            BranchRef(name: "release/stable", lastCommitDate: sameInstant),
            BranchRef(name: "feature/same-instant", lastCommitDate: sameInstant),
        ])
        #expect(snapshot.upstreams == ["main": "release/stable"])
        #expect(snapshot.defaultBranch == "release/stable")
        let entries = BranchPickerViewModel.entries(
            branchSnapshot: snapshot, mountedBranchToPath: [:], prsByBranch: [:], filterText: ""
        )
        #expect(entries.map(\.name) == [
            "feature/same-instant", "main", "release/stable", "history/1980", "history/epoch",
        ])
    }
}
