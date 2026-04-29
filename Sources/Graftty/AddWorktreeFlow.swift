import Foundation
import SwiftUI
import GrafttyKit

/// Shared "add a worktree" flow used by the native sidebar sheet (via
/// `MainWindow.addWorktree`) and the web client's `POST /worktrees`
/// endpoint (via `WebServerController`). Both entry points need the
/// same sequence — git invocation, eager discovery, append to
/// `AppState`, arm watchers, spawn the first terminal — and the same
/// error channel (git's stderr surfaced verbatim). Keeping the logic in
/// one place means the web flow can't drift out of parity with the
/// native sheet as the latter evolves.
///
/// This lives in the `Graftty` target rather than `GrafttyKit` because
/// `TerminalManager` and the SwiftUI bindings are not portable to a
/// kit-only consumer. `GrafttyKit` stays free of AppKit/SwiftUI/zmx
/// orchestration dependencies.
@MainActor
enum AddWorktreeFlow {

    /// The worktree name slots into `<repo>/.worktrees/<name>` and must
    /// not collide with an existing sibling. Stale entries count as
    /// collisions too: resurrecting via "just add with this name" would
    /// silently reuse a dismissed entry's split tree. Callers should
    /// surface this check early, before `git worktree add` fails with a
    /// less useful error.
    struct Result {
        let sessionName: String
        let worktreePath: String
    }

    enum FlowError: Error, Equatable {
        /// `git worktree add` returned non-zero. Holds the stderr text to
        /// display verbatim ("branch 'foo' already exists", "fatal: …").
        case gitFailed(String)
        /// The repo at `repoPath` was not in `AppState.repos` when the
        /// flow ran (e.g. the user removed the repo on the Mac while a
        /// web client kept its picker open). Surfaced as a plain string
        /// to the HTTP client; no git call is attempted.
        case repoNotFound
        /// The flow succeeded on the git side but the new worktree
        /// entry couldn't be discovered back. This is the
        /// "create-but-can't-attach" edge: we don't have a session to
        /// return. Holds the message.
        case discoveryFailed(String)
    }

    /// Execute the flow. On success the caller can observe:
    /// - a new `WorktreeEntry` in `appState.repos[<repo>].worktrees`,
    ///   already in `.running` state with surfaces created,
    /// - the FSEvents watchers armed for the new path,
    /// - the divergence stats poller primed.
    ///
    /// The native sheet additionally calls `selectWorktree(worktreePath)`
    /// to flip `selectedWorktreePath` and route keyboard focus. The web
    /// flow does not — remote-creating a worktree should not forcibly
    /// switch the focused Mac window away from whatever the local user
    /// is currently doing.
    static func add(
        repoPath: String,
        worktreeName: String,
        branchName: String,
        appState: Binding<AppState>,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        terminalManager: TerminalManager,
        channelDispatch: (@MainActor (String, ChannelServerMessage) -> Void)? = nil
    ) async -> Swift.Result<Result, FlowError> {
        guard appState.wrappedValue.repos.contains(where: { $0.path == repoPath }) else {
            return .failure(.repoNotFound)
        }

        let worktreePath = repoPath + "/.worktrees/" + worktreeName

        // Start from origin's default branch so fresh feature worktrees
        // branch off main rather than whatever the main checkout has
        // checked out right now (commonly a half-finished branch).
        let startPoint: String? = await GitOriginDefaultBranch.resolve(repoPath: repoPath)

        do {
            try await GitWorktreeAdd.add(
                repoPath: repoPath,
                worktreePath: worktreePath,
                branchName: branchName,
                startPoint: startPoint
            )
        } catch GitWorktreeAdd.Error.gitFailed(_, let stderr) {
            let msg = stderr.isEmpty ? "git worktree add failed" : stderr
            return .failure(.gitFailed(msg))
        } catch {
            return .failure(.gitFailed("\(error)"))
        }

        // Eager discovery so the new entry is in appState before we
        // attempt to spawn its terminal. FSEvents on `.git/worktrees/`
        // will also fire `worktreeMonitorDidDetectChange` asynchronously
        // — that path is idempotent, so duplicate discovery is a no-op.
        let discovered: [DiscoveredWorktree]
        do {
            discovered = try await GitWorktreeDiscovery.discover(repoPath: repoPath)
        } catch {
            return .failure(.discoveryFailed("\(error)"))
        }

        guard let repoIdx = appState.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else {
            return .failure(.repoNotFound)
        }
        let existingPaths = Set(appState.wrappedValue.repos[repoIdx].worktrees.map(\.path))
        for d in discovered where !existingPaths.contains(d.path) {
            let entry = WorktreeEntry(path: d.path, branch: d.branch)
            appState.wrappedValue.repos[repoIdx].worktrees.append(entry)
            worktreeMonitor.watchWorktreePath(entry.path)
            worktreeMonitor.watchHeadRef(worktreePath: entry.path, repoPath: repoPath)
            worktreeMonitor.watchWorktreeContents(worktreePath: entry.path)
            statsStore.refresh(worktreePath: entry.path, repoPath: repoPath, branch: entry.branch)
            if let dispatch = channelDispatch {
                TeamMembershipEvents.fireJoined(
                    repo: appState.wrappedValue.repos[repoIdx],
                    joinerWorktreePath: entry.path,
                    teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled),
                    dispatch: EventBodyRenderer.dispatchClosure(
                        repos: appState.wrappedValue.repos,
                        inner: { path, msg in dispatch(path, msg) }
                    )
                )
            }
        }

        // Start the first terminal for the new entry. Mirrors the
        // `.closed → .running` transition block inside
        // `MainWindow.selectWorktree`, minus the window-focus side
        // effects (first responder, PR refresh) that only make sense
        // when a user clicked the sidebar locally.
        guard let wtIdx = appState.wrappedValue.repos[repoIdx].worktrees
            .firstIndex(where: { $0.path == worktreePath }) else {
            return .failure(.discoveryFailed(
                "worktree created on disk but not discovered in repo state"
            ))
        }

        if appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree.root == nil {
            let id = TerminalID()
            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = SplitTree(root: .leaf(id))
        }

        let splitTree = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree
        for leafID in splitTree.allLeaves {
            terminalManager.markFirstPane(leafID)
        }
        _ = terminalManager.createSurfaces(for: splitTree, worktreePath: worktreePath)
        appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .running

        guard let firstLeaf = splitTree.allLeaves.first else {
            return .failure(.discoveryFailed("split tree produced no leaves"))
        }
        let sessionName = ZmxLauncher.sessionName(for: firstLeaf.id)
        return .success(Result(sessionName: sessionName, worktreePath: worktreePath))
    }
}
