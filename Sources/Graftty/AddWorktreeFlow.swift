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
/// The native sidebar splits the flow into `beginCreate` (sync,
/// inserts a `.creating` placeholder) + `finishCreate` (async, runs
/// git + spawn) so the sheet dismisses immediately while git's
/// pre-commit / post-checkout hooks run. The web flow stays blocking
/// via the `add` wrapper because its caller needs the returned
/// `sessionName` (for `zmx attach`) before the HTTP response goes back.
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
        /// A worktree already exists at the target path. Surfaced from
        /// `beginCreate` so two rapid submits with the same name don't
        /// produce two placeholders racing one git invocation.
        case pathCollision
        /// The flow succeeded on the git side but the new worktree
        /// entry couldn't be discovered back. This is the
        /// "create-but-can't-attach" edge: we don't have a session to
        /// return. Holds the message.
        case discoveryFailed(String)
    }

    /// Phase one: validate the request and insert a `.creating`
    /// placeholder. Returns the resolved worktree path on success — the
    /// caller passes this back to `finishCreate`.
    ///
    /// Synchronous and fast: no subprocess invocations, no awaits. The
    /// sheet's submit handler can call this and dismiss inline so the
    /// user isn't blocked on `git worktree add` (which can take seconds
    /// when pre-commit / post-checkout hooks run).
    static func beginCreate(
        repoPath: String,
        worktreeName: String,
        branchName: String,
        appState: Binding<AppState>
    ) -> Swift.Result<String, FlowError> {
        guard let repoIdx = appState.wrappedValue.repos
            .firstIndex(where: { $0.path == repoPath }) else {
            return .failure(.repoNotFound)
        }

        let worktreePath = repoPath + "/.worktrees/" + worktreeName

        // `git worktree add` would also reject the collision, but only
        // after we'd left a duplicate row in the sidebar — fail fast.
        if appState.wrappedValue.worktree(forPath: worktreePath) != nil {
            return .failure(.pathCollision)
        }

        var placeholder = WorktreeEntry(path: worktreePath, branch: branchName)
        placeholder.state = .creating
        appState.wrappedValue.repos[repoIdx].worktrees.append(placeholder)
        return .success(worktreePath)
    }

    /// Phase two: run `git worktree add`, discover the result, arm
    /// watchers, and spawn the first terminal. On success the
    /// placeholder transitions from `.creating` to `.running`; on
    /// failure the placeholder is removed and the error is returned for
    /// the caller to surface.
    ///
    /// `worktreePath` must equal what `beginCreate` returned so the
    /// transition / removal lands on the right row.
    static func finishCreate(
        repoPath: String,
        worktreePath: String,
        branchName: String,
        appState: Binding<AppState>,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        terminalManager: TerminalManager,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> Swift.Result<Result, FlowError> {
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
            removePlaceholder(at: worktreePath, appState: appState)
            let msg = stderr.isEmpty ? "git worktree add failed" : stderr
            return .failure(.gitFailed(msg))
        } catch {
            removePlaceholder(at: worktreePath, appState: appState)
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
            removePlaceholder(at: worktreePath, appState: appState)
            return .failure(.discoveryFailed("\(error)"))
        }

        guard let (repoIdx, wtIdx) = appState.wrappedValue
            .indices(forWorktreePath: worktreePath) else {
            return .failure(.discoveryFailed(
                "placeholder vanished from app state during create"
            ))
        }

        if let discoveredEntry = discovered.first(where: { $0.path == worktreePath }) {
            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch =
                discoveredEntry.branch
        }

        // Adopt any sibling-created worktrees that showed up in the
        // porcelain output (rare: another `git worktree add` from a
        // different process between this flow's start and discovery).
        let knownPaths = Set(appState.wrappedValue.repos[repoIdx].worktrees.map(\.path))
        var pathsToWire: [(path: String, branch: String)] = [(
            worktreePath,
            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch
        )]
        for d in discovered where !knownPaths.contains(d.path) {
            appState.wrappedValue.repos[repoIdx].worktrees
                .append(WorktreeEntry(path: d.path, branch: d.branch))
            pathsToWire.append((d.path, d.branch))
        }

        for (path, branch) in pathsToWire {
            worktreeMonitor.watchWorktreePath(path)
            worktreeMonitor.watchHeadRef(worktreePath: path, repoPath: repoPath)
            worktreeMonitor.watchWorktreeContents(worktreePath: path)
            statsStore.refresh(worktreePath: path, repoPath: repoPath, branch: branch)
        }

        TeamMembershipEvents.fireJoined(
            repo: appState.wrappedValue.repos[repoIdx],
            joinerWorktreePath: worktreePath,
            teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled),
            dispatcher: teamEventDispatcher
        )

        // Promote the placeholder. Mirrors the `.closed → .running`
        // transition block inside `MainWindow.selectWorktree`, minus
        // the window-focus side effects (first responder, PR refresh)
        // that only make sense when a user clicked the sidebar locally.
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

    /// Blocking convenience: run both phases inline. Used by the web
    /// `POST /worktrees` endpoint, whose response includes the
    /// `sessionName` the client needs for `zmx attach`. The native
    /// sidebar uses `beginCreate` + `finishCreate` separately so the
    /// sheet can dismiss optimistically.
    static func add(
        repoPath: String,
        worktreeName: String,
        branchName: String,
        appState: Binding<AppState>,
        worktreeMonitor: WorktreeMonitor,
        statsStore: WorktreeStatsStore,
        terminalManager: TerminalManager,
        teamEventDispatcher: TeamEventDispatcher
    ) async -> Swift.Result<Result, FlowError> {
        let worktreePath: String
        switch beginCreate(
            repoPath: repoPath,
            worktreeName: worktreeName,
            branchName: branchName,
            appState: appState
        ) {
        case .success(let p): worktreePath = p
        case .failure(let err): return .failure(err)
        }
        return await finishCreate(
            repoPath: repoPath,
            worktreePath: worktreePath,
            branchName: branchName,
            appState: appState,
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            terminalManager: terminalManager,
            teamEventDispatcher: teamEventDispatcher
        )
    }

    /// Drops the placeholder when phase two fails. The placeholder owns
    /// no surfaces and no caches yet — `beginCreate` only inserted a
    /// model entry — so `removeWorktree`'s plain remove is sufficient
    /// (it also clears `selectedWorktreePath` defensively, though
    /// `selectWorktree` already refuses to focus a `.creating` row).
    private static func removePlaceholder(
        at worktreePath: String,
        appState: Binding<AppState>
    ) {
        appState.wrappedValue.removeWorktree(atPath: worktreePath)
    }
}

extension AddWorktreeFlow.FlowError {
    /// User-facing message for surfacing in the sheet, an alert, or an
    /// HTTP response. `discoveryFailed` returns nil because callers log
    /// it (the worktree IS on disk; we just couldn't confirm it back)
    /// rather than display it — see `GIT-3.12`.
    var userMessage: String? {
        switch self {
        case .gitFailed(let m): return m
        case .repoNotFound: return "repository no longer tracked"
        case .pathCollision: return "a worktree at that name already exists"
        case .discoveryFailed: return nil
        }
    }
}
