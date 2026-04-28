import Testing
import Foundation
@testable import GrafttyKit

@Suite("AppState Tests")
struct AppStateTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func emptyStateHasNoRepos() {
        let state = AppState()
        #expect(state.repos.isEmpty)
        #expect(state.selectedWorktreePath == nil)
    }

    @Test func addRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ])
        state.addRepo(repo)
        #expect(state.repos.count == 1)
    }

    @Test func addDuplicateRepoIsIgnored() {
        var state = AppState()
        let repo1 = RepoEntry(path: "/tmp/repo", displayName: "repo")
        let repo2 = RepoEntry(path: "/tmp/repo", displayName: "repo-dup")
        state.addRepo(repo1)
        state.addRepo(repo2)
        #expect(state.repos.count == 1)
    }

    @Test func removeRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo")
        state.addRepo(repo)
        state.removeRepo(atPath: "/tmp/repo")
        #expect(state.repos.isEmpty)
    }

    @Test func saveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ]))
        state.selectedWorktreePath = "/tmp/repo"
        state.sidebarWidth = 280

        try state.save(to: dir)

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.count == 1)
        #expect(loaded.repos[0].path == "/tmp/repo")
        #expect(loaded.selectedWorktreePath == "/tmp/repo")
        #expect(loaded.sidebarWidth == 280)
    }

    /// STATE-6.2 (regression guard): `save(to:)` must throw on I/O
    /// failure so the caller can log / surface it. `GrafttyApp` used
    /// `try? newState.save(...)` for a long time, which silently
    /// discarded the error — a full disk or a read-only `$HOME` would
    /// lose every subsequent state mutation. The fix there is do/catch +
    /// NSLog (cf. ATTN-2.7 for the socket-server analogue); this test
    /// pins the underlying contract that `save` actually throws.
    @Test func saveThrowsWhenTargetDirectoryCannotBeCreated() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a regular file where the save() call will try to
        // `createDirectory(at: blocker, ...)`. createDirectory on a
        // path that is already a *file* fails with NSFileWriteFileExists.
        let blocker = tmp.appendingPathComponent("blocker")
        try "not a directory".data(using: .utf8)!.write(to: blocker)

        let state = AppState()
        #expect(throws: Error.self) { try state.save(to: blocker) }
    }

    @Test func loadFromEmptyDirReturnsDefault() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.isEmpty)
    }

    @Test func worktreeForPathFindsCorrectEntry() {
        var state = AppState()
        let wt = WorktreeEntry(path: "/tmp/worktrees/feature", branch: "feature/x")
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
            wt,
        ]))
        let found = state.worktree(forPath: "/tmp/worktrees/feature")
        #expect(found?.branch == "feature/x")
    }

    @Test func worktreeForPathReturnsNilWhenNotFound() {
        let state = AppState()
        #expect(state.worktree(forPath: "/nonexistent") == nil)
    }

    @Test func windowFrameCustomValuesSurviveSaveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.windowFrame = WindowFrame(x: 500, y: 200, width: 1600, height: 1000)

        try state.save(to: dir)
        let loaded = try AppState.load(from: dir)

        #expect(loaded.windowFrame.x == 500)
        #expect(loaded.windowFrame.y == 200)
        #expect(loaded.windowFrame.width == 1600)
        #expect(loaded.windowFrame.height == 1000)
    }

    @Test func sidebarWidthCustomValueSurvivesSaveAndLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.sidebarWidth = 312.5

        try state.save(to: dir)
        let loaded = try AppState.load(from: dir)

        #expect(loaded.sidebarWidth == 312.5)
    }

    @Test func windowFrameEquatableDistinguishesByValue() {
        let a = WindowFrame(x: 0, y: 0, width: 800, height: 600)
        let b = WindowFrame(x: 0, y: 0, width: 800, height: 600)
        let c = WindowFrame(x: 1, y: 0, width: 800, height: 600)
        #expect(a == b)
        #expect(a != c)
    }

    /// Mirrors the CLI's `WorktreeResolver.isTracked` flow: the CLI loads
    /// the on-disk state.json and checks whether a PWD-derived path
    /// corresponds to a tracked worktree. This test exercises the same
    /// load → `worktree(forPath:)` pipeline to catch regressions that
    /// would make `graftty notify` silently accept or reject paths.
    @Test func cliTrackingCheckRoundTripsThroughStateJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
            WorktreeEntry(path: "/tmp/worktrees/feature", branch: "feature"),
        ]))
        try state.save(to: dir)

        let loaded = try AppState.load(from: dir)

        // Tracked paths are recognized.
        #expect(loaded.worktree(forPath: "/tmp/repo") != nil)
        #expect(loaded.worktree(forPath: "/tmp/worktrees/feature") != nil)

        // Untracked paths — including the worktrees' parent and a random
        // directory — are rejected.
        #expect(loaded.worktree(forPath: "/tmp/worktrees") == nil)
        #expect(loaded.worktree(forPath: "/Users/elsewhere") == nil)
    }

    /// When state.json is missing entirely (fresh install), the CLI's
    /// tracking check must fail closed — nothing is tracked, so every
    /// `notify` correctly errors out rather than silently no-op'ing against
    /// an empty in-memory state.
    @Test func cliTrackingCheckReturnsNilForMissingStateJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No save. `load` returns a default AppState with no repos.

        let loaded = try AppState.load(from: dir)
        #expect(loaded.repos.isEmpty)
        #expect(loaded.worktree(forPath: "/tmp/repo") == nil)
    }

    // A crashed mid-write, a hand-edited typo, or a schema mismatch
    // across Graftty versions can leave state.json in a state that
    // `JSONDecoder` rejects. The pre-fix call site (`try? load` + `??
    // AppState()`) silently fell back to an empty AppState and
    // overwrote the corrupt file on next save — total state loss from
    // Andy's perspective. `loadOrFreshBackingUpCorruption` preserves
    // the corrupt file under a timestamped name so the user can
    // recover manually while still getting a working app.

    @Test func loadOrFreshBacksUpCorruption() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = "{\"repos\":[not valid json"
        try garbage.write(to: dir.appendingPathComponent("state.json"),
                          atomically: true, encoding: .utf8)

        let state = AppState.loadOrFreshBackingUpCorruption(
            from: dir,
            now: { Date(timeIntervalSince1970: 100) }
        )

        // Returns an empty state so the app boots.
        #expect(state.repos.isEmpty)
        #expect(state.selectedWorktreePath == nil)

        // Backup exists with the original garbage content.
        let backupPath = dir.appendingPathComponent("state.json.corrupt.100000")
        #expect(FileManager.default.fileExists(atPath: backupPath.path))
        let backup = try String(contentsOf: backupPath, encoding: .utf8)
        #expect(backup == garbage)
    }

    @Test func loadOrFreshDoesNotBackUpValidFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = RepoEntry(path: "/tmp/r", displayName: "r", worktrees: [
            WorktreeEntry(path: "/tmp/r", branch: "main")
        ])
        var source = AppState()
        source.addRepo(repo)
        try source.save(to: dir)

        let state = AppState.loadOrFreshBackingUpCorruption(from: dir)
        #expect(state.repos.count == 1)

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!contents.contains { $0.hasPrefix("state.json.corrupt") })
    }

    @Test func loadOrFreshReturnsEmptyWhenNoFileExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState.loadOrFreshBackingUpCorruption(from: dir)
        #expect(state.repos.isEmpty)
        // Missing file is not corruption — no backup created.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!contents.contains { $0.hasPrefix("state.json.corrupt") })
    }

    // MARK: setFocusedTerminal — focus-preservation on worktree switch
    //
    // `TERM-2.3`: "When the user switches back to a running worktree,
    // the application shall restore keyboard focus to the pane that was
    // focused when the user last switched away." That guarantee requires
    // the UI to persist *which* pane had focus — otherwise a worktree
    // switch round-trip snaps focus back to the first leaf regardless of
    // where the user was typing.
    //
    // Before this helper existed, the TerminalContentView's
    // `onFocusTerminal` callback called only `TerminalManager.setFocus`
    // (the libghostty / SwiftUI side) and never touched the model —
    // `focusedTerminalID` drifted to whatever was last written by
    // sidebar clicks / pane splits / pane closes. The model shape has a
    // dedicated mutator so every focus-change site updates the persisted
    // truth in one call.

    @Test func setFocusedTerminalUpdatesTheMatchingWorktree() {
        let pane1 = TerminalID()
        let pane2 = TerminalID()
        let wt = WorktreeEntry(path: "/tmp/wt", branch: "main")
        let repo = RepoEntry(path: "/tmp/wt", displayName: "repo", worktrees: [wt])
        var state = AppState(repos: [repo])

        state.setFocusedTerminal(pane1, forWorktreePath: "/tmp/wt")
        #expect(state.worktree(forPath: "/tmp/wt")?.focusedTerminalID == pane1)

        state.setFocusedTerminal(pane2, forWorktreePath: "/tmp/wt")
        #expect(state.worktree(forPath: "/tmp/wt")?.focusedTerminalID == pane2)
    }

    @Test func setFocusedTerminalToNilClearsFocus() {
        let pane1 = TerminalID()
        var wt = WorktreeEntry(path: "/tmp/wt", branch: "main")
        wt.focusedTerminalID = pane1
        let repo = RepoEntry(path: "/tmp/wt", displayName: "repo", worktrees: [wt])
        var state = AppState(repos: [repo])

        state.setFocusedTerminal(nil, forWorktreePath: "/tmp/wt")
        #expect(state.worktree(forPath: "/tmp/wt")?.focusedTerminalID == nil)
    }

    @Test func setFocusedTerminalOnlyTouchesTheMatchingWorktree() {
        let paneA = TerminalID()
        let paneB = TerminalID()
        let wtA = WorktreeEntry(path: "/tmp/a", branch: "main")
        let wtB = WorktreeEntry(path: "/tmp/b", branch: "main")
        let repoA = RepoEntry(path: "/tmp/a", displayName: "A", worktrees: [wtA])
        let repoB = RepoEntry(path: "/tmp/b", displayName: "B", worktrees: [wtB])
        var state = AppState(repos: [repoA, repoB])

        state.setFocusedTerminal(paneA, forWorktreePath: "/tmp/a")
        state.setFocusedTerminal(paneB, forWorktreePath: "/tmp/b")

        #expect(state.worktree(forPath: "/tmp/a")?.focusedTerminalID == paneA)
        #expect(state.worktree(forPath: "/tmp/b")?.focusedTerminalID == paneB)
    }

    @Test func setFocusedTerminalOnUnknownPathIsANoOp() {
        let pane = TerminalID()
        let wt = WorktreeEntry(path: "/tmp/wt", branch: "main")
        let repo = RepoEntry(path: "/tmp/wt", displayName: "repo", worktrees: [wt])
        var state = AppState(repos: [repo])

        state.setFocusedTerminal(pane, forWorktreePath: "/tmp/nonexistent")
        #expect(state.worktree(forPath: "/tmp/wt")?.focusedTerminalID == nil)
    }

    // MARK: removeWorktree — Delete / Dismiss shared primitive (GIT-4.10)
    //
    // Both Delete Worktree (GIT-4.x) and Dismiss (GIT-3.6) remove an
    // entry from the model AND must drop per-path entries in the
    // observable stores (PRStatusStore, WorktreeStatsStore). Pre-GIT-
    // 4.10, Delete did NOT drop caches — orphan entries leaked in
    // `prStatusStore.infos[path]` etc. A subsequent same-path re-add
    // would briefly inherit stale cache data on its first reconcile
    // tick. Memory also grew over a long session where Andy created &
    // deleted many feature worktrees.
    //
    // `removeWorktree(atPath:)` is the shared primitive: removes from
    // `repos`, clears `selectedWorktreePath` if it was the target, and
    // returns the path so the caller can pass it to the stores' `clear`
    // methods. Unknown paths return nil — terse call sites don't need
    // to guard.

    @Test func removeWorktreeRemovesAndReturnsPath() {
        var state = AppState(repos: [
            RepoEntry(path: "/tmp/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/tmp/r", branch: "main"),
                WorktreeEntry(path: "/tmp/r/wt", branch: "feature"),
            ]),
        ])

        let removed = state.removeWorktree(atPath: "/tmp/r/wt")

        #expect(removed == "/tmp/r/wt")
        #expect(state.worktree(forPath: "/tmp/r/wt") == nil)
        #expect(state.worktree(forPath: "/tmp/r") != nil)
    }

    @Test func removeWorktreeClearsSelectionWhenItWasTheTarget() {
        var state = AppState(
            repos: [
                RepoEntry(path: "/tmp/r", displayName: "r", worktrees: [
                    WorktreeEntry(path: "/tmp/r/wt", branch: "feature"),
                ]),
            ],
            selectedWorktreePath: "/tmp/r/wt"
        )

        _ = state.removeWorktree(atPath: "/tmp/r/wt")

        #expect(state.selectedWorktreePath == nil)
    }

    @Test func removeWorktreeLeavesSelectionAloneWhenDifferent() {
        var state = AppState(
            repos: [
                RepoEntry(path: "/tmp/r", displayName: "r", worktrees: [
                    WorktreeEntry(path: "/tmp/r", branch: "main"),
                    WorktreeEntry(path: "/tmp/r/wt", branch: "feature"),
                ]),
            ],
            selectedWorktreePath: "/tmp/r"
        )

        _ = state.removeWorktree(atPath: "/tmp/r/wt")

        #expect(state.selectedWorktreePath == "/tmp/r")
    }

    @Test func removeWorktreeReturnsNilForUnknownPath() {
        var state = AppState(repos: [
            RepoEntry(path: "/tmp/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/tmp/r", branch: "main"),
            ]),
        ])

        let removed = state.removeWorktree(atPath: "/nowhere")
        #expect(removed == nil)
        #expect(state.worktree(forPath: "/tmp/r") != nil)
    }

    // MARK: worktreeIndicesMatching — backs the "Move to current
    // worktree" menu's auto-detect label and the model-side reassignment
    // primitive. Both share this helper to stay in lockstep.

    @Test func worktreeIndicesMatching_returnsLongestPrefix() {
        let state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/r", branch: "main"),
                WorktreeEntry(path: "/r/wt/feature", branch: "feature"),
            ]),
        ])
        // PWD inside the linked worktree must beat the main checkout
        // even though both `/r` and `/r/wt/feature` are prefixes.
        let match = state.worktreeIndicesMatching(path: "/r/wt/feature/src/foo.swift")
        #expect(match?.repo == 0)
        #expect(match?.worktree == 1)
    }

    @Test func worktreeIndicesMatching_returnsNilForUnrelatedPath() {
        let state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/r", branch: "main"),
            ]),
        ])
        #expect(state.worktreeIndicesMatching(path: "/somewhere/else") == nil)
    }

    @Test func worktreeIndicesMatching_doesNotFalsePartialPrefixMatch() {
        // Trailing-slash normalization: `/r/feat` must not match a
        // worktree at `/r/feature` by raw `hasPrefix`.
        let state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/r/feature", branch: "feature"),
            ]),
        ])
        #expect(state.worktreeIndicesMatching(path: "/r/feat") == nil)
        #expect(state.worktreeIndicesMatching(path: "/r/feature/src") != nil)
        #expect(state.worktreeIndicesMatching(path: "/r/feature") != nil)
    }

    // MARK: indicesOfWorktreeContaining — pane-to-worktree reverse lookup
    // used by the Move-to-worktree menu builders (PWD-1.4 / TERM-8.10).

    @Test func indicesOfWorktreeContaining_findsHostingWorktree() {
        let pane = TerminalID()
        let state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/r", branch: "main"),
                WorktreeEntry(
                    path: "/r/wt/feature",
                    branch: "feature",
                    splitTree: SplitTree(root: .leaf(pane))
                ),
            ]),
        ])
        let match = state.indicesOfWorktreeContaining(terminalID: pane)
        #expect(match?.repo == 0)
        #expect(match?.worktree == 1)
    }

    @Test func indicesOfWorktreeContaining_returnsNilForUnknownPane() {
        let state = AppState(repos: [
            RepoEntry(path: "/r", displayName: "r", worktrees: [
                WorktreeEntry(path: "/r", branch: "main"),
            ]),
        ])
        #expect(state.indicesOfWorktreeContaining(terminalID: TerminalID()) == nil)
    }

    @Test func worktreeIndicesMatching_searchesAcrossRepos() {
        let state = AppState(repos: [
            RepoEntry(path: "/a", displayName: "a", worktrees: [
                WorktreeEntry(path: "/a", branch: "main"),
            ]),
            RepoEntry(path: "/b", displayName: "b", worktrees: [
                WorktreeEntry(path: "/b", branch: "main"),
            ]),
        ])
        let match = state.worktreeIndicesMatching(path: "/b/lib/x.swift")
        #expect(match?.repo == 1)
        #expect(match?.worktree == 0)
    }

    // MARK: removeRepo — repository-lifecycle selection invariant (LAYOUT-4.3 prep)

    @Test func removeRepoClearsSelectionWhenSelectedWorktreeIsInsideRemovedRepo() {
        var state = AppState()
        let repo = RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main"),
            WorktreeEntry(path: "/tmp/repo/.worktrees/feature", branch: "feature")
        ])
        state.addRepo(repo)
        state.selectedWorktreePath = "/tmp/repo/.worktrees/feature"

        state.removeRepo(atPath: "/tmp/repo")

        #expect(state.repos.isEmpty)
        #expect(state.selectedWorktreePath == nil)
    }

    @Test func removeRepoPreservesSelectionWhenSelectedWorktreeIsInDifferentRepo() {
        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repoA", displayName: "A", worktrees: [
            WorktreeEntry(path: "/tmp/repoA", branch: "main")
        ]))
        state.addRepo(RepoEntry(path: "/tmp/repoB", displayName: "B", worktrees: [
            WorktreeEntry(path: "/tmp/repoB", branch: "main")
        ]))
        state.selectedWorktreePath = "/tmp/repoB"

        state.removeRepo(atPath: "/tmp/repoA")

        #expect(state.repos.count == 1)
        #expect(state.selectedWorktreePath == "/tmp/repoB")
    }

    @Test func removeRepoIsNoOpForUnknownPath() {
        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo"))
        state.selectedWorktreePath = "/tmp/repo"

        state.removeRepo(atPath: "/tmp/other")

        #expect(state.repos.count == 1)
        #expect(state.selectedWorktreePath == "/tmp/repo")
    }

    @Test func removeRepoClearsSelectionEvenWhenSelectionIsRepoMainCheckoutPath() {
        var state = AppState()
        state.addRepo(RepoEntry(path: "/tmp/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/tmp/repo", branch: "main")
        ]))
        state.selectedWorktreePath = "/tmp/repo"

        state.removeRepo(atPath: "/tmp/repo")

        #expect(state.selectedWorktreePath == nil)
    }
}
