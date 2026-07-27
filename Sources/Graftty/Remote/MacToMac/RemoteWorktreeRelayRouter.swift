import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

struct RelayedPaneTarget: Sendable, Equatable {
    let identity: RemoteMacIdentity
    let sessionName: String
}

struct RelayedWorktreeTarget: Sendable, Equatable {
    let identity: RemoteMacIdentity
    let path: String
}

struct RelayedRepositoryTarget: Sendable, Equatable {
    let identity: RemoteMacIdentity
    let repositoryID: String
}

/// Builds one-hop snapshots and owns the exact alias lookup tables used by
/// incoming Mobile terminal/control/management requests.
@MainActor
final class RemoteWorktreeRelayRouter {
    private var panesByAlias: [String: RelayedPaneTarget] = [:]
    private var worktreesByAlias: [String: RelayedWorktreeTarget] = [:]
    private var repositoriesByAlias: [String: RelayedRepositoryTarget] = [:]

    func promotedWorktrees(
        snapshots: [RemoteMacIdentity: [WorktreePanes]],
        remoteMacs: [RemoteMac]
    ) -> [WorktreePanes] {
        var nextPanes: [String: RelayedPaneTarget] = [:]
        var nextWorktrees: [String: RelayedWorktreeTarget] = [:]
        var promoted: [WorktreePanes] = []

        for remoteMac in remoteMacs {
            let identity = RemoteMacIdentity(remoteMac)
            for worktree in snapshots[identity] ?? [] {
                // A V2 peer may itself publish one-hop rows. Only its local
                // rows become our direct rows; promoting a depth-1 row would
                // create remote-of-remote traversal and A↔B loops.
                guard worktree.origin?.relayDepth ?? 0 == 0 else { continue }

                let worktreeAlias = Self.alias(
                    kind: "worktree",
                    identity: identity,
                    value: worktree.path
                )
                let repositoryAlias = Self.alias(
                    kind: "repository",
                    identity: identity,
                    value: worktree.repositoryID ?? worktree.repoDisplayName
                )
                nextWorktrees[worktreeAlias] = RelayedWorktreeTarget(
                    identity: identity,
                    path: worktree.path
                )

                let layout = worktree.layout.map {
                    promoteLayout(
                        $0,
                        identity: identity,
                        nextPanes: &nextPanes
                    )
                }
                promoted.append(WorktreePanes(
                    path: worktreeAlias,
                    displayName: worktree.displayName,
                    repoDisplayName: worktree.repoDisplayName,
                    repositoryID: repositoryAlias,
                    displayBranch: worktree.displayBranch,
                    state: worktree.state,
                    isMainCheckout: worktree.isMainCheckout,
                    prBadge: worktree.prBadge,
                    stats: worktree.stats,
                    attentionText: worktree.attentionText,
                    layout: layout,
                    origin: WorktreeOrigin(
                        deviceID: remoteMac.id,
                        deviceLabel: remoteMac.label,
                        relayDepth: 1
                    ),
                    route: WorktreeRoute(
                        repositoryID: repositoryAlias,
                        worktreeID: worktreeAlias
                    )
                ))
            }
        }

        panesByAlias = nextPanes
        worktreesByAlias = nextWorktrees
        return promoted
    }

    func removeAllRoutes() {
        panesByAlias.removeAll()
        worktreesByAlias.removeAll()
        repositoriesByAlias.removeAll()
    }

    func resolvePane(_ alias: String) -> RelayedPaneTarget? {
        panesByAlias[alias]
    }

    func resolveWorktree(_ alias: String) -> RelayedWorktreeTarget? {
        worktreesByAlias[alias]
    }

    func promotedRepositories(
        _ repositories: [RemoteRepositoryInfo],
        from remoteMac: RemoteMac
    ) -> [RemoteRepositoryInfo] {
        let identity = RemoteMacIdentity(remoteMac)
        return repositories.compactMap { repository in
            guard repository.origin?.relayDepth ?? 0 == 0 else { return nil }
            let alias = Self.alias(
                kind: "repository",
                identity: identity,
                value: repository.id
            )
            repositoriesByAlias[alias] = RelayedRepositoryTarget(
                identity: identity,
                repositoryID: repository.id
            )
            return RemoteRepositoryInfo(
                id: alias,
                displayName: repository.displayName,
                origin: WorktreeOrigin(
                    deviceID: remoteMac.id,
                    deviceLabel: remoteMac.label,
                    relayDepth: 1
                ),
                defaultBranchStatus: repository.defaultBranchStatus,
                branches: repository.branches
            )
        }
    }

    func resolveRepository(_ alias: String) -> RelayedRepositoryTarget? {
        repositoriesByAlias[alias]
    }

    func registerCreatedWorktree(
        identity: RemoteMacIdentity,
        path: String,
        paneSessionName: String
    ) -> (worktreeID: String, paneID: String) {
        let worktreeAlias = Self.alias(
            kind: "worktree",
            identity: identity,
            value: path
        )
        let paneAlias = Self.alias(
            kind: "pane",
            identity: identity,
            value: paneSessionName
        )
        worktreesByAlias[worktreeAlias] = RelayedWorktreeTarget(
            identity: identity,
            path: path
        )
        panesByAlias[paneAlias] = RelayedPaneTarget(
            identity: identity,
            sessionName: paneSessionName
        )
        return (worktreeAlias, paneAlias)
    }

    private func promoteLayout(
        _ layout: PaneLayoutNode,
        identity: RemoteMacIdentity,
        nextPanes: inout [String: RelayedPaneTarget]
    ) -> PaneLayoutNode {
        switch layout {
        case let .leaf(sessionName, title, attentionText, isBusy, attentionSource):
            let alias = Self.alias(
                kind: "pane",
                identity: identity,
                value: sessionName
            )
            nextPanes[alias] = RelayedPaneTarget(
                identity: identity,
                sessionName: sessionName
            )
            return .leaf(
                sessionName: alias,
                title: title,
                attentionText: attentionText,
                isBusy: isBusy,
                attentionSource: attentionSource
            )
        case let .split(direction, ratio, left, right):
            return .split(
                direction: direction,
                ratio: ratio,
                left: promoteLayout(
                    left,
                    identity: identity,
                    nextPanes: &nextPanes
                ),
                right: promoteLayout(
                    right,
                    identity: identity,
                    nextPanes: &nextPanes
                )
            )
        }
    }

    private static func alias(
        kind: String,
        identity: RemoteMacIdentity,
        value: String
    ) -> String {
        var bytes = Data(kind.utf8)
        bytes.append(0)
        bytes.append(Data(identity.id.value.utf8))
        bytes.append(0)
        bytes.append(identity.fingerprint.rawBytes)
        bytes.append(0)
        bytes.append(Data(value.utf8))
        let digest = SHA256.hash(data: bytes)
        return "relay-\(kind)-\(Data(digest).base64URLEncodedString())"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Adapts a downstream SSH terminal client to the host agent's byte-stream
/// interface so an authenticated one-hop client can attach through this Mac.
final class RelayedTerminalByteStream: GrafttyKit.TerminalByteStream, @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>

    private let client: any WebSocketClient & Sendable
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var closed = false
    private var claimedControl = false
    private var cols = 80
    private var rows = 24
    private let displayClientID = DisplayClientID(UUID().uuidString)

    init(client: any WebSocketClient & Sendable) {
        self.client = client
        var continuation: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.receiveTask = Task { [weak self] in
            guard let self else { return }
            await client.sendHello(
                clientID: displayClientID,
                kind: .mac,
                role: .interactive,
                visible: true,
                cols: 80,
                rows: 24
            )
            while !Task.isCancelled {
                do {
                    switch try await client.receive() {
                    case .binary(let data) where !data.isEmpty:
                        self.continuation.yield(data)
                    case .binary, .text:
                        break
                    }
                } catch {
                    self.continuation.finish()
                    return
                }
            }
        }
    }

    func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        let state = lock.withLock {
            (
                isOpen: !closed,
                shouldClaim: claimControlIfNeededLocked(),
                cols: cols,
                rows: rows
            )
        }
        guard state.isOpen else { return }
        if state.shouldClaim {
            await client.takeControl(
                clientID: displayClientID,
                kind: .mac,
                cols: state.cols,
                rows: state.rows
            )
        }
        try await client.send(.binary(bytes))
    }

    func resize(cols: Int, rows: Int) async {
        let state = lock.withLock {
            self.cols = cols
            self.rows = rows
            return (
                isOpen: !closed,
                shouldClaim: claimControlIfNeededLocked()
            )
        }
        guard state.isOpen else { return }
        if state.shouldClaim {
            await client.takeControl(
                clientID: displayClientID,
                kind: .mac,
                cols: cols,
                rows: rows
            )
        }
        await client.resize(cols: cols, rows: rows)
    }

    func close() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard !closed else { return nil }
            closed = true
            let task = receiveTask
            receiveTask = nil
            return task
        }
        task?.cancel()
        client.close()
        continuation.finish()
    }

    private func claimControlIfNeededLocked() -> Bool {
        guard !closed, !claimedControl else { return false }
        claimedControl = true
        return true
    }
}
