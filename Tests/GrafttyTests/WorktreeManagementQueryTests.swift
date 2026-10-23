import Foundation
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

/// Repository listing, session lookup and default-branch pulls through
/// `WorktreeManagement`, which the web REST routes and the paired-device
/// envelope share.
@MainActor
struct WorktreeManagementQueryTests {
    @MainActor
    private final class StateBox {
        var state: AppState
        init(_ state: AppState) { self.state = state }
        var binding: Binding<AppState> { Binding(get: { self.state }, set: { self.state = $0 }) }
    }

    private let origin = WorktreeOrigin(deviceID: .init(value: "mac"), deviceLabel: "Mac", relayDepth: 0)

    private func service(_ box: StateBox, root: URL, terminalManager: TerminalManager? = nil,
                         statsStore: WorktreeStatsStore? = nil) -> WorktreeManagement {
        let inbox = TeamInbox(rootDirectory: root.appendingPathComponent("inbox"))
        return WorktreeManagement(
            appState: box.binding,
            terminalManager: terminalManager ?? TerminalManager(socketPath: root.appendingPathComponent("control.sock").path),
            teamInbox: inbox,
            teamEventDispatcher: TeamEventDispatcher(inbox: inbox, preferencesProvider: { TeamEventRoutingPreferences() },
                                                     templateProvider: { "" }),
            worktreeMonitor: WorktreeMonitor(), statsStore: statsStore ?? WorktreeStatsStore(), prStatusStore: PRStatusStore(),
            remoteBranchStore: RemoteBranchStore(), worktreeCreations: CLIWorktreeCreationStore(),
            worktreeRemovals: CLIWorktreeRemovalStore(), localOrigin: origin
        )
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-wtm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: CanonicalPath.canonicalize(root.path), isDirectory: true)
    }

    @Test("Web repository rows carry no branch list; paired-device and relayed rows do")
    func repositoryRowsPerTransport() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = StateBox(AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/a", branch: "a"),
        ])]))
        let service = service(box, root: root)

        let web = service.repositories(includingBranches: false).map { WebServer.RepoInfo($0, includingBranches: false) }
        #expect(web == [WebServer.RepoInfo(path: "/repo", displayName: "Repo", defaultBranchStatus: nil, origin: origin)])

        let relayed = RemoteRepositoryInfo(id: "relay-repo", displayName: "Other", origin: origin,
            defaultBranchStatus: .init(branchName: "main", remoteRef: "origin/main", behindCount: 2),
            branches: [.init(name: "b", source: .local, lastCommitDate: Date(timeIntervalSince1970: 0),
                             mountedWorktreeID: nil, pullRequest: nil)])
        #expect(WebServer.RepoInfo(relayed, includingBranches: true) == WebServer.RepoInfo(path: "relay-repo",
            displayName: "Other", defaultBranchStatus: relayed.defaultBranchStatus, branches: relayed.branches, origin: origin))

        let paired = try #require(service.repositories(includingBranches: true).first)
        #expect(paired.id == "/repo" && paired.origin == origin && paired.defaultBranchStatus == nil)
        let unbranched = service.repositories(includingBranches: false)
        #expect(unbranched.allSatisfy { $0.branches.isEmpty })
    }

    @Test("A web attach resolves its session to the worktree its pane was recorded in")
    func sessionLookupUsesRecordedPanes() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneSlotID()
        let session = PaneSessionID()
        var worktree = WorktreeEntry(path: "/repo/.worktrees/a", branch: "a", state: .running)
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions = [pane: session]
        let box = StateBox(AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"), worktree,
        ])]))
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)
        manager.recordPaneSessions(for: worktree.splitTree, paneSessions: worktree.paneSessions, worktreePath: worktree.path)
        let service = service(box, root: root, terminalManager: manager)

        #expect(service.worktreePath(forSessionName: ZmxLauncher.sessionName(for: session)) == worktree.path)
        #expect(service.worktreePath(forSessionName: ZmxLauncher.sessionName(for: PaneSessionID())) == nil)
    }

    @Test("@spec WEB-4.12: If a web client attaches to a pane whose worktree has gone stale, then the application shall start its zmx attach child without the missing worktree directory as its working directory.")
    func sessionLookupSkipsStaleWorktrees() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneSlotID()
        let session = PaneSessionID()
        // GIT-3.4: a worktree deleted while running keeps its live panes.
        var worktree = WorktreeEntry(path: "/repo/.worktrees/gone", branch: "gone", state: .running)
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions = [pane: session]
        worktree.markStale()
        let box = StateBox(AppState(repos: [RepoEntry(path: "/repo", displayName: "Repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"), worktree,
        ])]))
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)
        manager.recordPaneSessions(for: worktree.splitTree, paneSessions: worktree.paneSessions, worktreePath: worktree.path)
        let service = service(box, root: root, terminalManager: manager)

        #expect(service.worktreePath(forSessionName: ZmxLauncher.sessionName(for: session)) == nil)
    }

    @Test("@spec WEB-7.14: When a web or paired-device client pulls a repository's default branch, the application shall fast-forward the main checkout and then refresh its divergence stats.")
    func pullRefreshesStats() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let originRepo = root.appendingPathComponent("origin.git").path
        let clone = root.appendingPathComponent("clone").path
        func git(_ args: [String], at path: String) async throws -> String {
            try await GitRunner.run(args: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                           "-c", "core.hooksPath=/dev/null"] + args, at: path)
        }
        _ = try await git(["init", "--bare", "--initial-branch=main", originRepo], at: root.path)
        _ = try await git(["clone", originRepo, clone], at: root.path)
        _ = try await git(["commit", "--allow-empty", "-m", "first"], at: clone)
        _ = try await git(["commit", "--allow-empty", "-m", "second"], at: clone)
        _ = try await git(["push", "origin", "main"], at: clone)
        _ = try await git(["reset", "--hard", "HEAD~1"], at: clone)
        let originHead = try await git(["rev-parse", "origin/main"], at: clone).trimmingCharacters(in: .whitespacesAndNewlines)

        final class Computes: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { count += 1; return count } }
            var value: Int { lock.withLock { count } }
        }
        let computes = Computes()
        let stats = WorktreeStatsStore(compute: { _, _, _, _ in
            // Behind until the pull lands; the refresh after it reports even.
            let behind = computes.next() == 1 ? 1 : 0
            return .init(defaultBranch: "main", stats: WorktreeStats(ahead: 0, behind: behind, insertions: 0, deletions: 0,
                upstreamRefs: UpstreamRefs(defaultRef: "origin/main")))
        }, fetch: { _ in })
        defer { stats.clear(worktreePath: clone) }
        let box = StateBox(AppState(repos: [RepoEntry(path: clone, displayName: "clone", worktrees: [
            WorktreeEntry(path: clone, branch: "main"),
        ])]))
        stats.refresh(worktreePath: clone, repoPath: clone, branch: "main")
        let primed = ContinuousClock.now + .seconds(10)
        while stats.stats[clone] == nil, ContinuousClock.now < primed { try await Task.sleep(for: .milliseconds(5)) }
        try #require(stats.stats[clone]?.behind == 1, "stats were not primed")

        let result = await service(box, root: root, statsStore: stats).pullDefaultBranch(repoPath: clone)

        guard case .success = result else {
            Issue.record("pull failed: \(result)")
            return
        }
        #expect(try await git(["rev-parse", "HEAD"], at: clone).trimmingCharacters(in: .whitespacesAndNewlines) == originHead)
        let refreshed = ContinuousClock.now + .seconds(10)
        while stats.stats[clone]?.behind != 0, ContinuousClock.now < refreshed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(computes.value == 2)
        #expect(stats.stats[clone]?.behind == 0)
    }
}
