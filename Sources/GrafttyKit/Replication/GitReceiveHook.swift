import Foundation
import GrafttyProtocol

/// Written by the parent for a receive process after SSH authentication. Never
/// decode this context from a remote request: authenticatedPeer and local paths
/// belong to the parent, and the child may claim only a delegation scope.
public struct GitReceiveHookContext: Codable, Sendable {
    public let delegationDirectory: String
    public let repositoryPath: String
    public let scope: GitDelegationScope
    public let authenticatedPeer: RemoteMacConnectionSummary.ID
    public init(delegationDirectory: String, repositoryPath: String, scope: GitDelegationScope,
                authenticatedPeer: RemoteMacConnectionSummary.ID) {
        self.delegationDirectory = delegationDirectory; self.repositoryPath = repositoryPath
        self.scope = scope; self.authenticatedPeer = authenticatedPeer
    }
}

public enum GitReceiveHookError: Error, Equatable {
    case malformedUpdates, deletionForbidden, invalidContext, nonCommitTarget, wrongRepository
}

/// Git invokes pre-receive with the complete proposed update set before it
/// changes any refs. Objects remain in Git's quarantine while this runs.
public enum GitReceiveHook {
    public static let maximumInputBytes = 256 * 1024
    public static let maximumContextBytes = 256 * 1024

    public static func script(executable: String, contextFile: String) -> String {
        "#!/bin/sh\nexec " + WorktreeAgentLaunchCommand.shellLiteral(executable)
            + " internal git-receive-check --context " + WorktreeAgentLaunchCommand.shellLiteral(contextFile) + "\n"
    }

    public static func readBounded(_ handle: FileHandle, maximumBytes: Int) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: min(16384, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw GitReceiveHookError.malformedUpdates }
        }
        return data
    }

    public static func validate(_ input: Data, context: GitReceiveHookContext,
                                executor: any CLIExecutor = CLIRunner(terminatesOnCancellation: true)) async throws {
        let updates = try parse(input)
        guard context.repositoryPath.hasPrefix("/"), context.delegationDirectory.hasPrefix("/"),
              !context.scope.refs.isEmpty, context.scope.refs.count <= 128 else { throw GitReceiveHookError.invalidContext }
        let store = GitDelegationStore(directory: URL(fileURLWithPath: context.delegationDirectory))
        _ = try store.authorize(context.scope, authenticatedPeer: context.authenticatedPeer)
        let permitted = Set(context.scope.refs.map { Data($0.utf8) })
        guard updates.allSatisfy({ permitted.contains(Data($0.ref.utf8)) }) else { throw GitDelegationError.unauthorized }
        let actual = GitDelegationScope(delegationID: context.scope.delegationID, generation: context.scope.generation,
            repositoryID: context.scope.repositoryID, remoteWorktreeID: context.scope.remoteWorktreeID, refs: updates.map(\.ref))
        _ = try store.authorize(actual, authenticatedPeer: context.authenticatedPeer)
        let deadline = GitCommandDeadline(timeout: .seconds(10))
        let bare = try await GitRunner.run(args: ["rev-parse", "--is-bare-repository"], at: context.repositoryPath,
            timeout: deadline.remaining(), using: executor)
        guard bare.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { throw GitReceiveHookError.wrongRepository }
        // Keep Git's quarantine environment intact so new objects are visible.
        // Explicit object type checks reject tags instead of peeling them to commits.
        for commit in Set(updates.map(\.newObject)) {
            let type = try await GitRunner.run(args: ["cat-file", "-t", commit], at: context.repositoryPath,
                timeout: deadline.remaining(), using: executor)
            guard type.trimmingCharacters(in: .whitespacesAndNewlines) == "commit" else { throw GitReceiveHookError.nonCommitTarget }
        }
        try Task.checkCancellation()
        // Object validation suspends. Recheck current authority before Git can
        // accept the transaction, including revocation or expiry during validation.
        _ = try store.authorize(actual, authenticatedPeer: context.authenticatedPeer)
    }

    struct Update: Equatable { let oldObject: String; let newObject: String; let ref: String }
    static func parse(_ input: Data) throws -> [Update] {
        guard !input.isEmpty, input.count <= maximumInputBytes, input.last == 10,
              let text = String(data: input, encoding: .utf8) else { throw GitReceiveHookError.malformedUpdates }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard !lines.isEmpty, lines.count <= 128 else { throw GitReceiveHookError.malformedUpdates }
        var updates: [Update] = []
        var seen = Set<Data>()
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw GitReceiveHookError.malformedUpdates }
            let old = String(fields[0]), new = String(fields[1]), ref = String(fields[2])
            guard [40, 64].contains(old.utf8.count), new.utf8.count == old.utf8.count,
                  (old + new).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  ref.hasPrefix("refs/heads/"), ref.utf8.count <= 1024,
                  !ref.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(Data(ref.utf8)).inserted else { throw GitReceiveHookError.malformedUpdates }
            guard new.contains(where: { $0 != "0" }) else { throw GitReceiveHookError.deletionForbidden }
            updates.append(Update(oldObject: old, newObject: new, ref: ref))
        }
        return updates
    }
}
