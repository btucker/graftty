import Foundation
import GrafttyProtocol

/// Why a worktree could not be created. Shared by the Mac app's
/// `AddWorktreeFlow` and the headless host, so every transport reports the
/// same failures.
public enum WorktreeCreationError: Error, Equatable, Sendable {
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
    /// @spec GIT-5.11
    /// `.useExisting(name, _)` was submitted but the same repo already
    /// has the branch mounted in another worktree. Holds the colliding
    /// worktree's path so the caller can surface it.
    case branchAlreadyMounted(at: String)
    /// A raw CLI/HTTP client supplied a name that the interactive UI
    /// would never emit (for example `../outside`). Holds the validation
    /// message so every surface reports the same rejection.
    case invalidInput(String)

    /// `git worktree add` failures, with an empty stderr replaced by a
    /// generic message.
    public init(gitAddFailure error: any Error) {
        if case GitWorktreeAdd.Error.gitFailed(_, let stderr) = error {
            self = .gitFailed(stderr.isEmpty ? "git worktree add failed" : stderr)
        } else {
            self = .gitFailed("\(error)")
        }
    }

    /// User-facing message for surfacing in the sheet, an alert, or an
    /// HTTP response. `discoveryFailed` returns nil because callers log
    /// it (the worktree IS on disk; we just couldn't confirm it back)
    /// rather than display it — see `GIT-3.12`.
    public var userMessage: String? {
        switch self {
        case .gitFailed(let m): return m
        case .repoNotFound: return "repository no longer tracked"
        case .pathCollision: return "a worktree at that name already exists"
        case .branchAlreadyMounted(let path):
            let base = (path as NSString).lastPathComponent
            return "branch is already mounted at " + base
        case .invalidInput(let message): return message
        case .discoveryFailed: return nil
        }
    }

    /// The message an asynchronous `graftty worktree add` reports. Unlike an
    /// interactive surface, the CLI has nowhere else to log a discovery
    /// failure, so it reports that detail too.
    public var operationFailureMessage: String {
        if case .discoveryFailed(let detail) = self { return detail }
        return userMessage ?? "worktree creation failed"
    }
}

/// A successful worktree removal. `dismissed == true` means the directory
/// was already gone and Git's record was pruned instead of removed.
public struct WorktreeRemovalOutcome: Equatable, Sendable {
    public let dismissed: Bool
    public init(dismissed: Bool) { self.dismissed = dismissed }
}

/// Why a worktree could not be removed. Shared by the Mac app's
/// `DeleteWorktreeFlow` and the headless host.
public enum WorktreeRemovalError: Error, Equatable, Sendable {
    /// `git worktree remove` failed in a way `--force` could resolve
    /// (uncommitted/untracked files). Carries stderr + a `git status
    /// --short` snapshot to surface in the failure UI.
    case gitFailedForceable(stderr: String, shortStatus: String)
    /// Failure that `--force` cannot help with: either `--force` was
    /// already attempted, or the failure class is structural (main
    /// checkout, non-git repo, git binary missing).
    case gitFailedFinal(String)
    /// `worktreePath` did not resolve to any tracked worktree.
    case notFound
    /// `worktreePath` resolved to the repo's main checkout, which
    /// `git worktree remove` refuses by design.
    case mainCheckoutRejected

    /// Why `DeleteWorktreeFlow` and `graftty worktree remove` refuse a row
    /// whose creation or removal is still running.
    public static let operationInProgressMessage = "a worktree operation is already in progress"
}

public extension AppState {
    /// Where a linked worktree named `worktreeName` lives in its repository.
    static func linkedWorktreePath(repoPath: String, worktreeName: String) -> String {
        repoPath + "/.worktrees/" + worktreeName
    }

    /// Phase one of worktree creation: validate the request and insert a
    /// `.creating` placeholder, returning its path. Synchronous, so two
    /// rapid requests for one name cannot both reach Git.
    mutating func insertCreatingWorktree(
        repoPath: String,
        worktreeName: String,
        branch: BranchSelection,
        base: String? = nil,
        creationOrigin: WorktreeHistory.Origin? = nil
    ) -> Result<String, WorktreeCreationError> {
        let usesExistingBranch: Bool
        if case .useExisting = branch {
            usesExistingBranch = true
        } else {
            usesExistingBranch = false
        }
        if let message = WorktreeCreationInput.validationError(
            worktreeName: worktreeName,
            branchName: branch.branchName,
            existing: usesExistingBranch,
            base: base
        ) {
            return .failure(.invalidInput(message))
        }
        guard let repoIdx = repos.firstIndex(where: { $0.path == repoPath }) else {
            return .failure(.repoNotFound)
        }

        let worktreePath = Self.linkedWorktreePath(repoPath: repoPath, worktreeName: worktreeName)

        // `git worktree add` would also reject the collision, but only
        // after we'd left a duplicate row in the sidebar — fail fast.
        if worktree(forPath: worktreePath) != nil {
            return .failure(.pathCollision)
        }

        if case .useExisting(let name, _) = branch,
           let existing = repos[repoIdx].branchMountedPath(name) {
            return .failure(.branchAlreadyMounted(at: existing))
        }

        let createdAt = Date()
        var placeholder = WorktreeEntry(path: worktreePath, branch: branch.branchName, createdAt: createdAt,
            creationOrigin: creationOrigin ?? .init(date: createdAt, source: .user))
        placeholder.state = .creating
        placeholder.creationProgress = WorktreeCreationProgress(startedAt: createdAt)
        repos[repoIdx].worktrees.append(placeholder)
        return .success(worktreePath)
    }
}


extension AppState {
    public mutating func recordCreationOutput(_ output: WorktreeCreationOutput, at path: String, operationID: String? = nil) {
        guard let index = indices(forWorktreePath: path),
              repos[index.repo].worktrees[index.worktree].creationProgress?.isPending == true,
              operationID == nil || repos[index.repo].worktrees[index.worktree].creationProgress?.operationID == operationID else { return }
        repos[index.repo].worktrees[index.worktree].creationProgress?.output = output.text
        repos[index.repo].worktrees[index.worktree].creationProgress?.outputTruncated = output.truncated
    }

    public mutating func transitionCreation(at path: String, to phase: WorktreeCreationProgress.Phase,
                                           error: String? = nil, now: Date = Date(), operationID: String? = nil) {
        guard let index = indices(forWorktreePath: path),
              operationID == nil || repos[index.repo].worktrees[index.worktree].creationProgress?.operationID == operationID else { return }
        if phase == .failed {
            // Keep diagnostics inspectable without offering to open a path Git
            // may never have created. Discovery can later resurrect a real checkout.
            if repos[index.repo].worktrees[index.worktree].state == .creating {
                if !FileManager.default.fileExists(atPath: path + "/.git") {
                    repos[index.repo].worktrees[index.worktree].markStale(at: now)
                } else {
                    repos[index.repo].worktrees[index.worktree].state = .closed
                }
            }
            repos[index.repo].worktrees[index.worktree].cancelExpectedLaunch()
        }
        repos[index.repo].worktrees[index.worktree].creationProgress?.transition(to: phase, error: error, now: now)
    }
}
