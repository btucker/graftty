import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("@spec PROJECT-1.0: Each repository entry shall record whether its on-disk path is tracked by git.")
struct RepoEntryIsGitTrackedTests {
    @Test("Default initializer marks new entries as git-tracked")
    func defaultsToGitTracked() {
        let repo = RepoEntry(path: "/tmp/x", displayName: "x")
        #expect(repo.isGitTracked == true)
    }

    @Test("Initializer accepts isGitTracked: false")
    func acceptsNonGit() {
        let repo = RepoEntry(path: "/tmp/y", displayName: "y", isGitTracked: false)
        #expect(repo.isGitTracked == false)
    }
}

@Suite("@spec PROJECT-1.5: When decoding a repository entry that lacks the isGitTracked key, the application shall default it to true so pre-feature state.json blobs load unchanged.")
struct RepoEntryIsGitTrackedDecodeTests {
    @Test("Pre-feature JSON without isGitTracked decodes as git-tracked")
    func decodeLegacyAsGitTracked() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "path": "/tmp/legacy",
            "displayName": "legacy",
            "worktrees": []
        }
        """.data(using: .utf8)!
        let repo = try JSONDecoder().decode(RepoEntry.self, from: json)
        #expect(repo.isGitTracked == true)
    }

    @Test("Non-git entry round-trips through encode/decode")
    func roundTripNonGit() throws {
        let original = RepoEntry(
            path: "/tmp/nongit",
            displayName: "nongit",
            worktrees: [],
            isGitTracked: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RepoEntry.self, from: data)
        #expect(decoded.isGitTracked == false)
        #expect(decoded.path == original.path)
        #expect(decoded.displayName == original.displayName)
    }
}

@Suite("@spec PROJECT-1.4: When WorktreeDiscovery.discover is invoked with a non-git-tracked repository, the application shall return exactly one synthesized DiscoveredWorktree with path equal to the repo path and branch \"main\", without invoking git.")
struct WorktreeDiscoveryFacadeTests {
    @Test("Non-git repo synthesizes a single main worktree")
    func nonGitReturnsSyntheticWorktree() async throws {
        let repo = RepoEntry(
            path: "/tmp/example",
            displayName: "example",
            isGitTracked: false
        )
        let results = try await WorktreeDiscovery.discover(repo: repo)
        #expect(results.count == 1)
        #expect(results[0].path == "/tmp/example")
        #expect(results[0].branch == "main")
    }
}

@Suite("@spec GIT-1.5: When the user selects via Add Repository a folder containing no .git entry up to the filesystem root, the application shall present a three-button choice — Initialize Git Repository, Add Without Git, Cancel — instead of the prior \"Not a Git Repository\" warning.")
struct AddRepositoryAlertTests {
    @Test("Three buttons in the documented order")
    func threeButtonsInOrder() {
        let buttons = AddRepositoryAlert.buttons
        #expect(buttons == ["Initialize Git Repository", "Add Without Git", "Cancel"])
    }

    @Test("Initialize Git Repository is the default")
    func initIsDefault() {
        #expect(AddRepositoryAlert.defaultButtonIndex == 0)
    }
}

@Suite("@spec GIT-1.7: When the user chooses Add Without Git, the application shall register a repository entry whose isGitTracked is false and whose worktree list contains exactly one entry with path equal to the folder path and branch equal to \"main\".")
struct AddWithoutGitTests {
    @Test("Builder produces a non-git RepoEntry with a single main worktree")
    func buildsNonGitRepoEntry() {
        let repo = AddRepositoryAlert.makeNonGitRepoEntry(
            atPath: "/tmp/proj",
            displayName: "proj",
            bookmark: nil
        )
        #expect(repo.isGitTracked == false)
        #expect(repo.path == "/tmp/proj")
        #expect(repo.worktrees.count == 1)
        #expect(repo.worktrees[0].path == "/tmp/proj")
        #expect(repo.worktrees[0].branch == "main")
    }
}

@Suite("@spec PROJECT-1.1: While a repository is not git-tracked, the application shall hide Add Worktree, Delete Worktree, and the PR-merged delete-offer affordance from its context menus.")
struct NonGitMenuVisibilityTests {
    @Test("Add Worktree affordance hidden for non-git repos")
    func addWorktreeHiddenForNonGit() {
        let nonGit = RepoEntry(path: "/tmp/x", displayName: "x", isGitTracked: false)
        #expect(SidebarMenuVisibility.showsAddWorktree(repo: nonGit) == false)
    }

    @Test("Add Worktree affordance shown for git-tracked repos")
    func addWorktreeShownForGit() {
        let git = RepoEntry(path: "/tmp/y", displayName: "y", isGitTracked: true)
        #expect(SidebarMenuVisibility.showsAddWorktree(repo: git) == true)
    }

    @Test("Delete Worktree hidden for the synthetic worktree of a non-git repo")
    func deleteWorktreeHiddenForSynthetic() {
        let nonGit = RepoEntry(
            path: "/tmp/x",
            displayName: "x",
            worktrees: [WorktreeEntry(path: "/tmp/x", branch: "main")],
            isGitTracked: false
        )
        let wt = nonGit.worktrees[0]
        #expect(SidebarMenuVisibility.showsDeleteWorktree(worktree: wt, repo: nonGit) == false)
    }
}

@Suite("@spec PROJECT-1.2: While a repository is not git-tracked, the application shall skip PR-status, remote-branch, and git-status polling for it.")
struct NonGitPollingGateTests {
    @Test("RemoteBranchStore tick skips non-git repos")
    @MainActor
    func remoteBranchTickSkipsNonGit() async {
        let counter = ListCallCounter()
        let store = RemoteBranchStore { repoPath in
            await counter.bump(repoPath: repoPath)
            return []
        }
        let ticker = ManualPollingTicker()
        let repos: [RepoEntry] = [
            RepoEntry(path: "/tmp/git-ok", displayName: "git", isGitTracked: true),
            RepoEntry(path: "/tmp/non-git", displayName: "ng", isGitTracked: false),
        ]
        store.start(ticker: ticker, getRepos: { repos })
        await ticker.fire()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await counter.snapshot()
        #expect(calls == ["/tmp/git-ok"])
        store.stop()
    }
}

private actor ListCallCounter {
    private var calls: [String] = []
    func bump(repoPath: String) { calls.append(repoPath) }
    func snapshot() -> [String] { calls }
}

// Test-only manual ticker. Mirrors `PollingTickerLike` shape from GrafttyKit.
@MainActor
private final class ManualPollingTicker: PollingTickerLike {
    private var onTick: (@MainActor () async -> Void)?
    func start(onTick: @MainActor @escaping () async -> Void) { self.onTick = onTick }
    func stop() { onTick = nil }
    func pulse() {}
    func fire() async { await onTick?() }
}

@Suite("@spec PROJECT-1.3: When the user selects Initialize Git Repository on a non-git repo's row, the application shall run `git init` + `git commit --allow-empty`, set `isGitTracked` to true, and rediscover its worktrees via `git worktree list --porcelain`.")
struct PromoteToGitTests {
    @Test("After GitInit + flag flip, WorktreeDiscovery returns real porcelain output")
    func promoteCreatesGitRepoAndDiscoversWorktree() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") ||
              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/git") ||
              FileManager.default.fileExists(atPath: "/usr/local/bin/git") else {
            return
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // `git worktree list --porcelain` reports the canonical (resolved)
        // path — on macOS `/var/folders/...` resolves to `/private/var/...`
        // — so compare via `URL.resolvingSymlinksInPath` to match.
        let canonicalTmp = tmpDir.resolvingSymlinksInPath().path

        try await GitInit.run(at: tmpDir.path)

        let promoted = RepoEntry(
            path: tmpDir.path,
            displayName: tmpDir.lastPathComponent,
            worktrees: [WorktreeEntry(path: tmpDir.path, branch: "main")],
            isGitTracked: true
        )
        let discovered = try await WorktreeDiscovery.discover(repo: promoted)
        #expect(discovered.count == 1)
        #expect(URL(fileURLWithPath: discovered[0].path).resolvingSymlinksInPath().path == canonicalTmp)
        #expect(!discovered[0].branch.isEmpty)
    }
}
