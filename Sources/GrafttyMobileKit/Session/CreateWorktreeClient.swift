#if canImport(UIKit)
import Foundation

public enum CreateWorktreeClient {

    public struct Request: Sendable, Equatable {
        public let repoPath: String
        public let worktreeName: String
        public let branchName: String
        public let existing: Bool

        public init(
            repoPath: String,
            worktreeName: String,
            branchName: String,
            existing: Bool = false
        ) {
            self.repoPath = repoPath
            self.worktreeName = worktreeName
            self.branchName = branchName
            self.existing = existing
        }
    }

    public enum CreateError: Error, Equatable {
        case serverInternal(String)
        case transport
    }
}

extension CreateWorktreeClient.CreateError {
    public var userMessage: String {
        switch self {
        case .serverInternal(let msg): return msg
        case .transport: return "Couldn't reach the server."
        }
    }
}
#endif
