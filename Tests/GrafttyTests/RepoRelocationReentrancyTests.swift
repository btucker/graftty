import Foundation
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@MainActor
private final class RelocationState {
    var state: AppState { didSet { onWrite?(state) } }
    var onWrite: ((AppState) -> Void)?
    init(_ repos: [RepoEntry]) { state = AppState(repos: repos) }
    var binding: Binding<AppState> { Binding(get: { self.state }, set: { self.state = $0 }) }
}

@MainActor
private final class RelocationSuspension {
    private let arrivals: AsyncStream<Void>
    private let arrival: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation

    init() {
        (arrivals, arrival) = AsyncStream<Void>.makeStream()
        (releases, release) = AsyncStream<Void>.makeStream()
    }

    func pause() async {
        arrival.yield(())
        var events = releases.makeAsyncIterator()
        _ = await events.next()
    }

    func waitForArrival() async {
        var events = arrivals.makeAsyncIterator()
        _ = await events.next()
    }

    func open() { release.finish() }
}

@MainActor
private final class RelocationFixture {
    let root: URL
    let monitor = WorktreeMonitor()
    let stats = WorktreeStatsStore()
    let prs = PRStatusStore()
    let branches = RemoteBranchStore()

    init(realGit: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relocation-reentrancy-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        root = URL(fileURLWithPath: CanonicalPath.canonicalize(directory.path))
        if realGit {
            try git(["init", "-b", "main", root.path])
            try git(["-C", root.path, "config", "core.hooksPath", "/dev/null"])
            try git(["-C", root.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "--allow-empty", "-m", "Initial"])
            try git(["-C", root.path, "branch", "created"])
        }
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    func create(_ box: RelocationState, name: String = "created", branchName: String? = nil, expectSuccess: Bool = true,
                beforeFinish: (@MainActor () async -> Void)? = nil,
                discover: @MainActor (String) async throws -> [DiscoveredWorktree]) async {
        let branch = BranchSelection.useExisting(name: branchName ?? name, source: .local)
        let result = AddWorktreeFlow.beginCreate(repoPath: root.path, worktreeName: name,
                                               branch: branch, appState: box.binding)
        guard case .success(let path) = result else {
            if expectSuccess { Issue.record("Creation rejected: \(result)") }
            return
        }
        if let beforeFinish { await beforeFinish() }
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)
        let created = await AddWorktreeFlow.finishCreate(
            repoPath: root.path, worktreePath: path, branch: branch, appState: box.binding,
            worktreeMonitor: monitor, statsStore: stats, terminalManager: manager,
            teamEventDispatcher: TeamEventDispatcher(inbox: TeamInbox(rootDirectory: root.appendingPathComponent("inbox")),
                preferencesProvider: { TeamEventRoutingPreferences() }, templateProvider: { "" }),
            terminalStartTiming: .onClientAttach, discover: discover
        )
        switch created {
        case .failure(let error):
            if expectSuccess { Issue.record("Creation failed: \(error)") }
        case .success:
            #expect(expectSuccess, "Creation unexpectedly succeeded")
        }
    }

    func cleanUp() {
        monitor.stopAll()
        try? FileManager.default.removeItem(at: root)
    }

    func relocate(_ box: RelocationState,
                  discover: @MainActor (RepoEntry) async throws -> [DiscoveredWorktree],
                  repair: @MainActor (String, [String]) async throws -> Void = { _, _ in }) async {
        await GrafttyApp.relocateRepo(
            appState: box.binding, worktreeMonitor: monitor, statsStore: stats,
            prStatusStore: prs, remoteBranchStore: branches, repoIdx: 0,
            newURL: root, isStale: false, discover: discover, repair: repair
        )
    }

    /// Hold the real orchestrator open while a separate main-actor task edits its model.
    func relocate(_ box: RelocationState, suspendedAt stage: String,
                  discovered: [DiscoveredWorktree], whileSuspended edit: () -> Void) async {
        let (arrivals, arrival) = AsyncStream<Void>.makeStream()
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let task = Task {
            await relocate(box, discover: { _ in
                calls += 1
                if (stage == "discovery" && calls == 1) || (stage == "rediscovery" && calls == 2) {
                    await withCheckedContinuation { gate = $0; arrival.yield(()) }
                }
                return calls == 1 && stage != "discovery" ? [] : discovered
            }, repair: { _, _ in
                if stage == "repair" {
                    await withCheckedContinuation { gate = $0; arrival.yield(()) }
                }
            })
        }
        var events = arrivals.makeAsyncIterator()
        _ = await events.next()
        edit()
        gate?.resume()
        await task.value
        arrival.finish()
    }
}

@Suite("@spec LAYOUT-4.13: When discovery or repair suspends during repository relocation, the application shall merge relocation decisions by worktree identity into current rows, preserving concurrent layout, state, order, additions, and removals without duplicate discoveries.")
@MainActor
struct RepoRelocationWorktreeMergeTests {
    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func alreadyPresentAliasKeepsItsConcurrentPaneState(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let original = WorktreeEntry(path: "/old", branch: "main")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [original])])
        var alias = WorktreeEntry(path: fixture.root.path, branch: "main", state: .running)
        let pane = PaneSlotID()
        alias.splitTree = SplitTree(root: .leaf(pane))
        alias.focusedPaneSlotID = pane
        alias.attention = Attention(text: "new alias state", timestamp: Date())
        await fixture.relocate(box, suspendedAt: stage, discovered: [
            DiscoveredWorktree(path: fixture.root.path, branch: "main")
        ]) {
            box.state.repos[0].worktrees.append(alias)
        }
        #expect(box.state.repos[0].worktrees.first { $0.id == alias.id } == alias)
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func concurrentWorktreeEditsSurvive(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let main = WorktreeEntry(path: "/old", branch: "main")
        let removed = WorktreeEntry(path: "/old/removed", branch: "removed")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [main, removed])])
        let added = WorktreeEntry(path: fixture.root.path + "/added", branch: "added", state: .running)
        let local = WorktreeEntry(path: fixture.root.path + "/local", branch: "local")
        var edited = main
        let first = PaneSlotID()
        let second = PaneSlotID()
        edited.splitTree = SplitTree(root: .leaf(first)).inserting(second, at: first, direction: .horizontal)
        edited.focusedPaneSlotID = second
        edited.primaryPaneSlotID = first
        edited.state = .running
        edited.isPinned = true
        edited.attention = Attention(text: "new attention", timestamp: Date(timeIntervalSince1970: 123))
        edited.paneAttention[second] = edited.attention
        let discoveries = [
            DiscoveredWorktree(path: fixture.root.path, branch: "main"),
            DiscoveredWorktree(path: fixture.root.path + "/removed", branch: "removed"),
            DiscoveredWorktree(path: added.path, branch: added.branch),
            DiscoveredWorktree(path: fixture.root.path + "/fresh", branch: "fresh")
        ]
        await fixture.relocate(box, suspendedAt: stage, discovered: discoveries) {
            box.state.repos[0].worktrees = [added, edited, local]
        }
        edited.path = fixture.root.path
        let actual = box.state.repos[0].worktrees
        #expect(Array(actual.prefix(3)) == [added, edited, local])
        #expect(actual.count == 4)
        #expect(actual.last?.branch == "fresh")
        #expect(!actual.contains { $0.id == removed.id || $0.branch == removed.branch })
        #expect(actual.filter { $0.path == added.path }.count == 1)
        #expect(actual.filter { $0.path == edited.path }.map(\.id) == [edited.id])
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func staleRowsKeepConcurrentEditsAndRemovedStaleRowsStayRemoved(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let missing = WorktreeEntry(path: "/old/missing", branch: "missing")
        let removed = WorktreeEntry(path: "/old/removed", branch: "removed")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [missing, removed])])
        var edited = missing
        edited.isPinned = true
        edited.emoji = "🐝"
        edited.markStale(at: Date(timeIntervalSince1970: 123))
        await fixture.relocate(box, suspendedAt: stage, discovered: []) {
            box.state.repos[0].worktrees = [edited]
        }
        #expect(box.state.repos[0].worktrees == [edited])
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func removedIdentityDestinationCanBeReplaced(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let original = WorktreeEntry(path: "/old", branch: "main")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [original])])
        var replacement = WorktreeEntry(path: fixture.root.path, branch: "main", state: .running)
        replacement.splitTree = SplitTree(root: .leaf(PaneSlotID()))
        box.state.selectedWorktreePath = original.path
        await fixture.relocate(box, suspendedAt: stage, discovered: [
            DiscoveredWorktree(path: fixture.root.path, branch: "main")
        ]) {
            box.state.repos[0].worktrees = [replacement]
            box.state.selectedWorktreePath = replacement.path
        }
        #expect(box.state.repos[0].worktrees == [replacement])
        #expect(box.state.selectedWorktreePath == replacement.path)
    }
}

@Suite("@spec LAYOUT-4.15: While repository relocation is in progress, concurrent worktree creation shall defer sibling adoption until relocation finishes and discovery is current, preserving original worktree identities and pane edits while retaining genuinely new siblings.")
@MainActor
struct RepoRelocationCreationTests {
    @Test func failedCreationCannotLeaveAnAliasAtAMovedCheckout() async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let siblingPath = fixture.root.path + "/.worktrees/sibling"
        try fixture.git(["-C", fixture.root.path, "worktree", "add", "-b", "sibling", siblingPath])
        let original = WorktreeEntry(path: "/old/.worktrees/sibling", branch: "sibling")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [original])])
        let gate = RelocationSuspension()
        let relocation = Task {
            await fixture.relocate(box, discover: { _ in
                await gate.pause()
                return try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
            })
        }
        defer { relocation.cancel(); gate.open() }
        await gate.waitForArrival()
        await fixture.create(box, name: "sibling", branchName: "created", expectSuccess: false,
                             discover: { try await GitWorktreeDiscovery.discover(repoPath: $0) })
        #expect(box.state.repos[0].worktrees.map(\.id) == [original.id])
        gate.open()
        await relocation.value
        #expect(box.state.repos[0].worktrees.filter { $0.path == siblingPath }.map(\.id) == [original.id])
    }

    @Test(arguments: [false, true], [false, true])
    func completedRelocationInvalidatesSuspendedDiscovery(alreadyActive: Bool, fails: Bool) async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let oldPath = alreadyActive ? "/old" : fixture.root.path
        let main = WorktreeEntry(path: oldPath, branch: "main")
        let repo = RepoEntry(path: oldPath, displayName: "target", worktrees: [main])
        let box = RelocationState([repo])
        let relocationGate = RelocationSuspension()
        let discoveryGate = RelocationSuspension()
        let startRelocation = {
            Task { @MainActor in
                await fixture.relocate(box, discover: { _ in
                    await relocationGate.pause()
                    if fails { throw CocoaError(.fileReadUnknown) }
                    return try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
                })
            }
        }
        var relocation: Task<Void, Never>?
        if alreadyActive {
            relocation = startRelocation()
            await relocationGate.waitForArrival()
        }
        defer { relocation?.cancel(); relocationGate.open(); discoveryGate.open() }
        var calls = 0
        let creation = Task {
            await fixture.create(box, expectSuccess: !fails, discover: { path in
                calls += 1
                let result = try await GitWorktreeDiscovery.discover(repoPath: path)
                if calls == 1 { await discoveryGate.pause() }
                return result
            })
        }
        defer { creation.cancel() }
        await discoveryGate.waitForArrival()
        if !alreadyActive {
            relocation = startRelocation()
            await relocationGate.waitForArrival()
        }
        relocationGate.open()
        await relocation?.value
        #expect(!GrafttyApp.isRelocatingRepo(repo.id))
        discoveryGate.open()
        await creation.value
        #expect(calls == (fails ? 1 : 2))
        #expect(box.state.repos[0].worktrees.filter { $0.branch == "main" }.map(\.id) == [main.id])
        #expect(box.state.worktree(forPath: fixture.root.path + "/.worktrees/created")?.creationProgress?.phase == (fails ? .failed : .ready))
    }

    @Test(arguments: [false, true])
    func anotherRelocationKeepsCreationWaiting(duringRediscovery: Bool) async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let main = WorktreeEntry(path: "/old", branch: "main")
        let repo = RepoEntry(path: "/old", displayName: "target", worktrees: [main])
        let box = RelocationState([repo])
        let firstGate = RelocationSuspension()
        let secondGate = RelocationSuspension()
        let rediscoveryGate = RelocationSuspension()
        let first = Task {
            await fixture.relocate(box, discover: { _ in
                let result = try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
                await firstGate.pause()
                return result
            })
        }
        defer { first.cancel(); firstGate.open(); secondGate.open(); rediscoveryGate.open() }
        await firstGate.waitForArrival()
        let (arrivals, arrival) = AsyncStream<Int>.makeStream()
        defer { arrival.finish() }
        var calls = 0
        var finished = false
        let creation = Task {
            await fixture.create(box, discover: { path in
                calls += 1
                let result = try await GitWorktreeDiscovery.discover(repoPath: path)
                if duringRediscovery && calls == 2 { await rediscoveryGate.pause() }
                arrival.yield(calls)
                return result
            })
            finished = true
        }
        defer { creation.cancel() }
        var events = arrivals.makeAsyncIterator()
        #expect(await events.next() == 1)
        if duringRediscovery {
            firstGate.open()
            await first.value
            await rediscoveryGate.waitForArrival()
        }
        let second = Task {
            await fixture.relocate(box, discover: { _ in
                let result = try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
                await secondGate.pause()
                return result
            })
        }
        defer { second.cancel() }
        await secondGate.waitForArrival()
        if duringRediscovery {
            rediscoveryGate.open()
            #expect(await events.next() == 2)
        } else {
            firstGate.open()
            await first.value
        }
        #expect(GrafttyApp.isRelocatingRepo(repo.id), "An older completion must not clear the newer relocation")
        #expect(!finished, "Adoption must wait for the newer relocation too")
        secondGate.open()
        await second.value
        await creation.value
        #expect(!GrafttyApp.isRelocatingRepo(repo.id))
        #expect(calls == (duringRediscovery ? 3 : 2))
        #expect(box.state.repos[0].worktrees.filter { $0.branch == "main" }.map(\.id) == [main.id])
    }

    @Test func creationDoesNotAdoptMovedAliases() async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let siblingPath = fixture.root.path + "/.worktrees/sibling"
        let removedPath = fixture.root.path + "/.worktrees/removed"
        try fixture.git(["-C", fixture.root.path, "worktree", "add", "-b", "sibling", siblingPath])
        try fixture.git(["-C", fixture.root.path, "worktree", "add", "-b", "removed", removedPath])
        let main = WorktreeEntry(path: "/old", branch: "main")
        let sibling = WorktreeEntry(path: "/old/.worktrees/sibling", branch: "sibling")
        let removed = WorktreeEntry(path: "/old/.worktrees/removed", branch: "removed")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [main, sibling, removed])])
        let (relocationArrivals, relocationArrival) = AsyncStream<Void>.makeStream()
        var releaseRelocation: CheckedContinuation<Void, Never>?
        let relocation = Task {
            await fixture.relocate(box, discover: { _ in
                let discovered = try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
                await withCheckedContinuation { releaseRelocation = $0; relocationArrival.yield(()) }
                return discovered
            })
        }
        var relocationEvents = relocationArrivals.makeAsyncIterator()
        _ = await relocationEvents.next()
        let (creationArrivals, creationArrival) = AsyncStream<Void>.makeStream()
        var discoveryCalls = 0
        let creation = Task {
            await fixture.create(box, discover: { path in
                discoveryCalls += 1
                let result = try await GitWorktreeDiscovery.discover(repoPath: path)
                creationArrival.yield(())
                return result
            })
        }
        var creationEvents = creationArrivals.makeAsyncIterator()
        _ = await creationEvents.next()
        // Creation has finished discovery. Adoption must wait, without inventing
        // another identity for main or any of the moved siblings.
        #expect(box.state.repos[0].worktrees.filter { $0.branch == "main" }.map(\.id) == [main.id])
        #expect(box.state.repos[0].worktrees.filter { $0.branch == "sibling" }.map(\.id) == [sibling.id])
        let pane = PaneSlotID()
        box.state.repos[0].worktrees[0].splitTree = SplitTree(root: .leaf(pane))
        box.state.repos[0].worktrees[0].state = .running
        try fixture.git(["-C", fixture.root.path, "worktree", "remove", "--force", removedPath])
        box.state.removeWorktree(atPath: removed.path)
        let freshPath = fixture.root.path + "/.worktrees/fresh"
        try fixture.git(["-C", fixture.root.path, "worktree", "add", "-b", "fresh", freshPath])
        releaseRelocation?.resume()
        await relocation.value
        await creation.value
        relocationArrival.finish()
        creationArrival.finish()
        let worktrees = box.state.repos[0].worktrees
        #expect(worktrees.filter { $0.branch == "main" }.map(\.id) == [main.id])
        #expect(worktrees.filter { $0.branch == "sibling" }.map(\.id) == [sibling.id])
        #expect(worktrees.first { $0.id == main.id }?.splitTree.allLeaves == [pane])
        #expect(!worktrees.contains { $0.branch == "removed" })
        #expect(worktrees.contains { $0.path == freshPath })
        #expect(worktrees.first { $0.branch == "created" }?.state == .running)
        #expect(discoveryCalls == 2)
    }

    @Test func ordinaryCreationStillAdoptsNewSiblings() async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let siblingPath = fixture.root.path + "/.worktrees/sibling"
        try fixture.git(["-C", fixture.root.path, "worktree", "add", "-b", "sibling", siblingPath])
        let main = WorktreeEntry(path: fixture.root.path, branch: "main")
        let box = RelocationState([RepoEntry(path: fixture.root.path, displayName: "target", worktrees: [main])])
        var calls = 0
        await fixture.create(box, discover: { path in
            calls += 1
            return try await GitWorktreeDiscovery.discover(repoPath: path)
        })
        #expect(box.state.repos[0].worktrees.first { $0.path == main.path }?.id == main.id)
        #expect(box.state.repos[0].worktrees.contains { $0.path == siblingPath })
        #expect(box.state.repos[0].worktrees.first { $0.branch == "created" }?.state == .running)
        #expect(calls == 1)
    }
}

@Suite("@spec LAYOUT-4.16: If relocation fails, is cancelled, or its repository is removed, then the application shall fail waiting worktree creation without adopting stale siblings; cancelling one waiting creation shall leave relocation and other waiting creations active.")
@MainActor
struct RepoRelocationCreationExitTests {
    @Test func relocationFailureBetweenCreationPhasesIsRemembered() async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let main = WorktreeEntry(path: "/old", branch: "main")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [main])])
        let gate = RelocationSuspension()
        let relocation = Task {
            await fixture.relocate(box, discover: { _ in
                await gate.pause()
                throw CocoaError(.fileReadUnknown)
            })
        }
        defer { relocation.cancel(); gate.open() }
        await gate.waitForArrival()
        var calls = 0
        await fixture.create(box, expectSuccess: false, beforeFinish: {
            gate.open()
            await relocation.value
        }, discover: { path in
            calls += 1
            return try await GitWorktreeDiscovery.discover(repoPath: path)
        })
        #expect(calls == 0)
        #expect(box.state.repos[0].worktrees.filter { $0.branch == "main" }.map(\.id) == [main.id])
        #expect(box.state.worktree(forPath: fixture.root.path + "/.worktrees/created")?.creationProgress?.phase == .failed)
    }

    @Test func relocationFailureDuringGitIsRememberedBeforeDiscovery() async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let hooks = fixture.root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let releaseHook = fixture.root.appendingPathComponent("release-hook")
        let hook = hooks.appendingPathComponent("post-checkout")
        try """
        #!/bin/sh
        printf '%s\\n' relocation-test-hook
        attempt=0
        while [ "$attempt" -lt 1000 ]; do
          [ -f \(WorktreeAgentLaunchCommand.shellLiteral(releaseHook.path)) ] && exit 0
          /bin/sleep 0.01
          attempt=$((attempt + 1))
        done
        exit 1

        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try fixture.git(["-C", fixture.root.path, "config", "core.hooksPath", hooks.path])
        defer { try? Data().write(to: releaseHook) }
        let main = WorktreeEntry(path: "/old", branch: "main")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [main])])
        let gate = RelocationSuspension()
        let relocation = Task {
            await fixture.relocate(box, discover: { _ in
                await gate.pause()
                throw CocoaError(.fileReadUnknown)
            })
        }
        defer { relocation.cancel(); gate.open() }
        await gate.waitForArrival()
        let (arrivals, arrival) = AsyncStream<Void>.makeStream()
        box.onWrite = { state in
            if state.worktree(forPath: fixture.root.path + "/.worktrees/created")?
                .creationProgress?.output.contains("relocation-test-hook") == true {
                arrival.yield(())
            }
        }
        defer { box.onWrite = nil; arrival.finish() }
        var discoveryCalls = 0
        let creation = Task {
            await fixture.create(box, expectSuccess: false, discover: { path in
                discoveryCalls += 1
                return try await GitWorktreeDiscovery.discover(repoPath: path)
            })
            arrival.finish()
        }
        defer { creation.cancel() }
        var events = arrivals.makeAsyncIterator()
        try #require(await events.next() != nil, "Git must reach its post-checkout hook")
        gate.open()
        await relocation.value
        try Data().write(to: releaseHook)
        await creation.value
        #expect(discoveryCalls == 0)
        #expect(box.state.repos[0].worktrees.filter { $0.branch == "main" }.map(\.id) == [main.id])
        #expect(box.state.worktree(forPath: fixture.root.path + "/.worktrees/created")?.creationProgress?.phase == .failed)
    }

    @Test func repositoryReplacementIsUntouchedByWaitingCreation() async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [WorktreeEntry(path: "/old", branch: "main")])])
        let relocationGate = RelocationSuspension()
        let discoveryGate = RelocationSuspension()
        let relocation = Task {
            await fixture.relocate(box, discover: { _ in
                await relocationGate.pause()
                return try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
            })
        }
        defer { relocation.cancel(); relocationGate.open(); discoveryGate.open() }
        await relocationGate.waitForArrival()
        let creation = Task {
            await fixture.create(box, expectSuccess: false, discover: { path in
                let result = try await GitWorktreeDiscovery.discover(repoPath: path)
                await discoveryGate.pause()
                return result
            })
        }
        defer { creation.cancel() }
        await discoveryGate.waitForArrival()
        let replacement = RepoEntry(path: fixture.root.path, displayName: "replacement", worktrees: box.state.repos[0].worktrees)
        box.state.repos = [replacement]
        relocationGate.open()
        await relocation.value
        discoveryGate.open()
        await creation.value
        #expect(box.state.repos == [replacement])
    }

    @Test(arguments: ["failure", "removal", "cancellation"])
    func relocationExitReleasesWaitingCreation(_ exit: String) async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        let repo = RepoEntry(path: "/old", displayName: "target", worktrees: [WorktreeEntry(path: "/old", branch: "main")])
        let box = RelocationState([repo])
        let gate = RelocationSuspension()
        let relocation = Task {
            await fixture.relocate(box, discover: { _ in
                await gate.pause()
                if exit == "failure" { throw CocoaError(.fileReadUnknown) }
                try Task.checkCancellation()
                return try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
            })
        }
        defer { relocation.cancel(); gate.open() }
        await gate.waitForArrival()
        let (arrivals, arrival) = AsyncStream<Void>.makeStream()
        defer { arrival.finish() }
        var finished = false
        var calls = 0
        let creation = Task {
            await fixture.create(box, expectSuccess: false, discover: { path in
                calls += 1
                let result = try await GitWorktreeDiscovery.discover(repoPath: path)
                arrival.yield(())
                return result
            })
            finished = true
        }
        defer { creation.cancel() }
        var events = arrivals.makeAsyncIterator()
        _ = await events.next()
        #expect(!finished)
        if exit == "removal" { box.state.repos.removeAll() }
        if exit == "cancellation" { relocation.cancel() }
        gate.open()
        await relocation.value
        await creation.value
        #expect(finished)
        #expect(calls == 1)
        #expect(!GrafttyApp.isRelocatingRepo(repo.id))
        if exit == "removal" {
            #expect(box.state.repos.isEmpty)
        } else {
            #expect(box.state.repos[0].worktrees.filter { $0.branch == "main" }.map(\.id) == [repo.worktrees[0].id])
            #expect(box.state.worktree(forPath: fixture.root.path + "/.worktrees/created")?.creationProgress?.phase == .failed)
        }
    }

    @Test func cancellingOneCreationDoesNotCancelOtherWaiters() async throws {
        let fixture = try RelocationFixture(realGit: true)
        defer { fixture.cleanUp() }
        try fixture.git(["-C", fixture.root.path, "branch", "other"])
        let repo = RepoEntry(path: "/old", displayName: "target", worktrees: [WorktreeEntry(path: "/old", branch: "main")])
        let box = RelocationState([repo])
        let gate = RelocationSuspension()
        let relocation = Task {
            await fixture.relocate(box, discover: { _ in
                await gate.pause()
                return try await GitWorktreeDiscovery.discover(repoPath: fixture.root.path)
            })
        }
        defer { relocation.cancel(); gate.open() }
        await gate.waitForArrival()
        let (arrivals, arrival) = AsyncStream<Void>.makeStream()
        defer { arrival.finish() }
        let discover: @MainActor (String) async throws -> [DiscoveredWorktree] = { path in
            let result = try await GitWorktreeDiscovery.discover(repoPath: path)
            arrival.yield(())
            return result
        }
        let cancelled = Task { await fixture.create(box, expectSuccess: false, discover: discover) }
        var events = arrivals.makeAsyncIterator()
        _ = await events.next()
        var otherFinished = false
        let other = Task {
            await fixture.create(box, name: "other", discover: discover)
            otherFinished = true
        }
        defer { cancelled.cancel(); other.cancel() }
        _ = await events.next()
        cancelled.cancel()
        await cancelled.value
        #expect(box.state.worktree(forPath: fixture.root.path + "/.worktrees/created")?.creationProgress?.phase == .failed)
        #expect(GrafttyApp.isRelocatingRepo(repo.id))
        #expect(!otherFinished)
        gate.open()
        await relocation.value
        await other.value
        #expect(otherFinished)
        #expect(box.state.worktree(forPath: fixture.root.path + "/.worktrees/other")?.state == .running)
    }
}

@Suite("@spec LAYOUT-4.14: When selection changes while repository relocation is suspended, the application shall resolve the latest selection by current worktree identity, relocate a selected surviving worktree, clear a selected stale worktree, and preserve a selected replacement, selection outside the relocation, or an explicit deselection.")
@MainActor
struct RepoRelocationSelectionMergeTests {
    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func selectionBelongsToReplacementAtReusedPath(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let original = WorktreeEntry(path: "/external", branch: "old-branch")
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: [original])])
        let replacement = WorktreeEntry(path: original.path, branch: "new-branch")
        await fixture.relocate(box, suspendedAt: stage, discovered: [
            DiscoveredWorktree(path: replacement.path, branch: replacement.branch)
        ]) {
            box.state.repos[0].worktrees = [replacement]
            box.state.selectedWorktreePath = replacement.path
        }
        #expect(box.state.repos[0].worktrees == [replacement])
        #expect(box.state.selectedWorktreePath == replacement.path)
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"], ["surviving", "stale", "outside", "none"])
    func latestSelectionSurvives(_ stage: String, selection: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let worktrees = [WorktreeEntry(path: "/old", branch: "main"),
                         WorktreeEntry(path: "/old/linked", branch: "linked"),
                         WorktreeEntry(path: "/old/stale", branch: "stale")]
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target", worktrees: worktrees)])
        box.state.selectedWorktreePath = "/old"
        let latest: String?
        let expected: String?
        switch selection {
        case "surviving": latest = "/old/linked"; expected = fixture.root.path + "/linked"
        case "stale": latest = "/old/stale"; expected = nil
        case "outside": latest = "/other"; expected = latest
        default: latest = nil; expected = nil
        }
        await fixture.relocate(box, suspendedAt: stage, discovered: [
            DiscoveredWorktree(path: fixture.root.path, branch: "main"),
            DiscoveredWorktree(path: fixture.root.path + "/linked", branch: "linked")
        ]) {
            box.state.selectedWorktreePath = latest
        }
        #expect(box.state.selectedWorktreePath == expected)
    }
}

@Suite("@spec LAYOUT-4.11: When repository discovery or repair suspends during relocation, the application shall apply the result only to the same repository identity at the expected path, preserving other repositories and skipping a removed repository.")
@MainActor
struct RepoRelocationReentrancyTests {
    @Test(arguments: ["discovery", "repair", "rediscovery"])
    func reorderDuringSuspension(_ stage: String) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let target = RepoEntry(path: "/old", displayName: "target", worktrees: [WorktreeEntry(path: "/old", branch: "main")])
        let other = RepoEntry(path: "/other", displayName: "other", worktrees: [WorktreeEntry(path: "/other", branch: "other")])
        let box = RelocationState([target, other])
        var calls = 0
        await fixture.relocate(box, discover: { repo in
            calls += 1
            if stage == "discovery" || (stage == "rediscovery" && calls == 2) {
                await Task.yield()
                box.state.repos.swapAt(0, 1)
            }
            if stage != "discovery" && calls == 1 { return [] }
            #expect(repo.id == target.id, "rediscovery must read the relocated repository")
            return [DiscoveredWorktree(path: fixture.root.path, branch: "main")]
        }, repair: { _, _ in
            if stage == "repair" {
                await Task.yield()
                box.state.repos.swapAt(0, 1)
            }
        })
        #expect(box.state.repos.first(where: { $0.id == other.id }) == other)
        #expect(box.state.repos.first(where: { $0.id == target.id })?.worktrees.first?.path == fixture.root.path)
    }

    @Test(arguments: ["discovery", "repair", "rediscovery"], [false, true])
    func invalidatedRepositoryIsNotReplacedByItsResult(_ stage: String, movedAgain: Bool) async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let target = RepoEntry(path: "/old", displayName: "target", worktrees: [WorktreeEntry(path: "/old", branch: "main")])
        var replacement = movedAgain ? target : RepoEntry(path: fixture.root.path, displayName: "replacement")
        if movedAgain { replacement.path = "/newer-location" }
        let box = RelocationState([target])
        var calls = 0
        await fixture.relocate(box, discover: { _ in
            calls += 1
            if stage == "discovery" || (stage == "rediscovery" && calls == 2) {
                await Task.yield()
                box.state.repos = [replacement]
                box.state.selectedWorktreePath = "/replacement-selection"
            }
            return calls == 1 && stage != "discovery" ? [] : [DiscoveredWorktree(path: fixture.root.path, branch: "main")]
        }, repair: { _, _ in
            if stage == "repair" {
                await Task.yield()
                box.state.repos = [replacement]
            }
        })
        #expect(box.state.repos == [replacement])
        if stage != "repair" { #expect(box.state.selectedWorktreePath == "/replacement-selection") }
        if stage == "repair" { #expect(calls == 1, "removed repositories must not be rediscovered") }
    }

    @Test func removingTheLastRepositoryDuringDiscoveryIsSafe() async throws {
        let fixture = try RelocationFixture()
        defer { fixture.cleanUp() }
        let box = RelocationState([RepoEntry(path: "/old", displayName: "target")])
        await fixture.relocate(box, discover: { _ in
            await Task.yield()
            box.state.repos.removeAll()
            return []
        })
        #expect(box.state.repos.isEmpty)
    }

}

@Suite("@spec LAYOUT-4.12: When a repository is removed while launch-time location resolution suspends, the application shall continue resolving the remaining original repository identities without using stale array offsets.")
@MainActor
struct RepoLocationResolutionReentrancyTests {
    @Test func launchResolutionSurvivesReorderingAndRemoval() async throws {
        let first = try RelocationFixture()
        let second = try RelocationFixture()
        defer { first.cleanUp(); second.cleanUp() }
        let a = RepoEntry(path: "/old-a", displayName: "a", bookmark: try RepoBookmark.mint(atPath: first.root.path))
        let b = RepoEntry(path: "/old-b", displayName: "b", bookmark: try RepoBookmark.mint(atPath: second.root.path))
        let decoy = RepoEntry(path: "/decoy", displayName: "decoy")
        let box = RelocationState([a, b])
        var discoveredIDs: [UUID] = []
        await GrafttyApp.resolveRepoLocations(
            appState: box.binding, worktreeMonitor: first.monitor, statsStore: first.stats,
            prStatusStore: first.prs, remoteBranchStore: first.branches,
            discover: { repo in
                discoveredIDs.append(repo.id)
                if repo.id == a.id {
                    await Task.yield()
                    box.state.repos = [b, decoy]
                }
                return []
            }
        )
        #expect(discoveredIDs == [a.id, b.id])
        #expect(box.state.repos.first?.path == second.root.path)
        #expect(box.state.repos.last == decoy)
    }
}
