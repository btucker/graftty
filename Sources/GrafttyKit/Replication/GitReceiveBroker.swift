import Foundation
import GrafttyProtocol

/// Holds prepared receivers until a data channel authenticates and claims them.
/// Callers must check current pairing permission before each control or data call.
public actor GitReceiveBroker {
    typealias Prepare = @Sendable (GitDelegationScope, RemoteMacConnectionSummary.ID, GitReplicaObjectFormat) async throws -> GitReceiveCommand
    public static let maximumRequestBytes = 256 * 1024
    public static let maximumPending = 32
    public static let validForSeconds = 30
    private struct Pending {
        let command: GitReceiveCommand
        let scope: GitDelegationScope
        let deadline: ContinuousClock.Instant
    }
    private let delegations: GitDelegationStore
    private let prepare: Prepare
    private let now: @Sendable () -> ContinuousClock.Instant
    private var pending: [UUID: Pending] = [:]
    private var preparing = 0
    private var closed = false

    public init(delegations: GitDelegationStore, replicas: GitReplicaStore) {
        self.delegations = delegations
        self.now = { .now }
        self.prepare = { scope, peer, format in
            try await replicas.prepareReceive(scope: scope, authenticatedPeer: peer, objectFormat: format)
        }
    }
    init(delegations: GitDelegationStore, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, prepare: @escaping Prepare) {
        self.delegations = delegations; self.now = now; self.prepare = prepare
    }

    public func handle(_ data: Data, authenticatedPeer: RemoteMacConnectionSummary.ID) async -> GitReplicationResponse {
        guard data.count <= Self.maximumRequestBytes,
              let request = try? JSONDecoder().decode(GitReplicationRequest.self, from: data) else { return .error(.invalidRequest) }
        guard !closed, !Task.isCancelled else { return .error(.unavailable) }
        switch request {
        case .prepareReceive(let scope, let format):
            do { _ = try delegations.authorize(scope, authenticatedPeer: authenticatedPeer) }
            catch { return .error(.unauthorized) }
            expire()
            guard pending.count + preparing < Self.maximumPending else { return .error(.busy) }
            preparing += 1
            defer { preparing -= 1 }
            do {
                let command = try await prepare(scope, authenticatedPeer, format)
                // No process has received this command yet; it is safe to remove
                // its hooks if shutdown, cancellation, or revocation won the race.
                var retained = false
                defer { if !retained { discard(command) } }
                guard !closed else { return .error(.unavailable) }
                try Task.checkCancellation()
                _ = try delegations.authorize(scope, authenticatedPeer: authenticatedPeer)
                let token = UUID()
                pending[token] = Pending(command: command, scope: scope,
                    deadline: now().advanced(by: .seconds(Self.validForSeconds)))
                retained = true
                return .receiveReady(token: token, validForSeconds: Self.validForSeconds)
            } catch is GitDelegationError { return .error(.unauthorized) }
            catch { return .error(.unavailable) }
        }
    }

    /// On success, the transport owns process lifetime and hook cleanup. Keep the
    /// hook directory until the process and all children have exited.
    public func claim(_ token: UUID, authenticatedPeer: RemoteMacConnectionSummary.ID) throws -> GitReceiveCommand {
        try Task.checkCancellation()
        expire()
        guard !closed, let receive = pending[token] else { throw GitReplicationError.invalidToken }
        // The same immutable assignment was authorized at preparation. Its
        // current generation binds the claiming channel to exactly that peer.
        _ = try delegations.authorize(receive.scope, authenticatedPeer: authenticatedPeer)
        pending.removeValue(forKey: token)
        return receive.command
    }

    public func close() {
        closed = true
        for receive in pending.values { discard(receive.command) }
        pending.removeAll()
    }

    private func expire() {
        let instant = now()
        for (token, receive) in pending where receive.deadline <= instant {
            pending.removeValue(forKey: token)
            discard(receive.command)
        }
    }

    private func discard(_ command: GitReceiveCommand) {
        // Never delete the bare repository or any claimed process's hook.
        try? FileManager.default.removeItem(at: command.hooksDirectory)
    }
}
