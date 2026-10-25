import GrafttyProtocol

/// The paired-device create/delete envelope shared by the Mac and headless hosts.
public extension WorktreeManagementResponse {
    static func creationFailure(message: String?) -> Self {
        .error(code: "create-failed", message: message ?? "could not create worktree",
               forceAllowed: false, shortStatus: nil)
    }

    /// The paired-device envelope's `delete`.
    init(removal result: Result<WorktreeRemovalOutcome, WorktreeRemovalError>) {
        switch result {
        case .success(let outcome): self = .deleted(dismissed: outcome.dismissed)
        case .failure(.notFound):
            self = .error(code: "not-found", message: "unknown worktree", forceAllowed: false, shortStatus: nil)
        case .failure(.mainCheckoutRejected):
            self = .error(code: "invalid", message: "cannot delete the main checkout", forceAllowed: false, shortStatus: nil)
        case .failure(.gitFailedForceable(let stderr, let status)):
            self = .error(code: "git-failed", message: stderr, forceAllowed: true, shortStatus: status)
        case .failure(.gitFailedFinal(let message)):
            self = .error(code: "git-failed", message: message, forceAllowed: false, shortStatus: nil)
        }
    }
}
