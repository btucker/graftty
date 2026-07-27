import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

struct RelayedPaneTarget: Sendable, Equatable {
    let identity: RemoteMacIdentity
    let worktreePath: String
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
    private struct PendingRoute<T> {
        let target: T
        let expiresAt: Date
    }

    private var panesByAlias: [String: RelayedPaneTarget] = [:]
    private var worktreesByAlias: [String: RelayedWorktreeTarget] = [:]
    private var repositoriesByAlias: [String: RelayedRepositoryTarget] = [:]
    private var mountedWorktreesByAlias:
        [String: RelayedWorktreeTarget] = [:]
    private var pendingPanesByAlias:
        [String: PendingRoute<RelayedPaneTarget>] = [:]
    private var pendingWorktreesByAlias:
        [String: PendingRoute<RelayedWorktreeTarget>] = [:]
    private let now: @Sendable () -> Date
    private let pendingRouteLifetime: TimeInterval

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        pendingRouteLifetime: TimeInterval = 60
    ) {
        self.now = now
        self.pendingRouteLifetime = pendingRouteLifetime
    }

    func promotedWorktrees(
        snapshots: [RemoteMacIdentity: [WorktreePanes]],
        remoteMacs: [RemoteMac]
    ) -> [WorktreePanes] {
        pruneExpiredPendingRoutes()
        let activeIdentities = Set(snapshots.keys)
        pendingPanesByAlias = pendingPanesByAlias.filter {
            activeIdentities.contains($0.value.target.identity)
        }
        pendingWorktreesByAlias = pendingWorktreesByAlias.filter {
            activeIdentities.contains($0.value.target.identity)
        }
        repositoriesByAlias = repositoriesByAlias.filter {
            activeIdentities.contains($0.value.identity)
        }
        mountedWorktreesByAlias = mountedWorktreesByAlias.filter {
            activeIdentities.contains($0.value.identity)
        }
        var nextPanes = pendingPanesByAlias.mapValues(\.target)
        var nextWorktrees = mountedWorktreesByAlias
        nextWorktrees.merge(
            pendingWorktreesByAlias.mapValues(\.target),
            uniquingKeysWith: { _, pending in pending }
        )
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
                pendingWorktreesByAlias[worktreeAlias] = nil

                let layout = worktree.layout.map {
                    promoteLayout(
                        $0,
                        identity: identity,
                        worktreePath: worktree.path,
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
                    attentionSource: worktree.attentionSource,
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
        mountedWorktreesByAlias.removeAll()
        pendingPanesByAlias.removeAll()
        pendingWorktreesByAlias.removeAll()
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
        let staleMountedAliases = mountedWorktreesByAlias.compactMap {
            alias, target in
            target.identity == identity ? alias : nil
        }
        for alias in staleMountedAliases {
            worktreesByAlias[alias] = nil
        }
        repositoriesByAlias = repositoriesByAlias.filter {
            $0.value.identity != identity
        }
        mountedWorktreesByAlias = mountedWorktreesByAlias.filter {
            $0.value.identity != identity
        }
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
            let branches = repository.branches.map { branch in
                let mountedAlias = branch.mountedWorktreeID.map { path in
                    let worktreeAlias = Self.alias(
                        kind: "worktree",
                        identity: identity,
                        value: path
                    )
                    let target = RelayedWorktreeTarget(
                        identity: identity,
                        path: path
                    )
                    mountedWorktreesByAlias[worktreeAlias] = target
                    worktreesByAlias[worktreeAlias] = target
                    return worktreeAlias
                }
                return RemoteRepositoryInfo.Branch(
                    name: branch.name,
                    source: branch.source,
                    lastCommitDate: branch.lastCommitDate,
                    mountedWorktreeID: mountedAlias,
                    pullRequest: branch.pullRequest
                )
            }
            return RemoteRepositoryInfo(
                id: alias,
                displayName: repository.displayName,
                origin: WorktreeOrigin(
                    deviceID: remoteMac.id,
                    deviceLabel: remoteMac.label,
                    relayDepth: 1
                ),
                defaultBranchStatus: repository.defaultBranchStatus,
                branches: branches
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
            worktreePath: path,
            sessionName: paneSessionName
        )
        let expiresAt = now().addingTimeInterval(pendingRouteLifetime)
        pendingWorktreesByAlias[worktreeAlias] = PendingRoute(
            target: worktreesByAlias[worktreeAlias]!,
            expiresAt: expiresAt
        )
        pendingPanesByAlias[paneAlias] = PendingRoute(
            target: panesByAlias[paneAlias]!,
            expiresAt: expiresAt
        )
        return (worktreeAlias, paneAlias)
    }

    func registerCreatedPane(
        identity: RemoteMacIdentity,
        worktreePath: String,
        sessionName: String
    ) -> String {
        let alias = Self.alias(
            kind: "pane",
            identity: identity,
            value: sessionName
        )
        let target = RelayedPaneTarget(
            identity: identity,
            worktreePath: worktreePath,
            sessionName: sessionName
        )
        panesByAlias[alias] = target
        pendingPanesByAlias[alias] = PendingRoute(
            target: target,
            expiresAt: now().addingTimeInterval(pendingRouteLifetime)
        )
        return alias
    }

    private func promoteLayout(
        _ layout: PaneLayoutNode,
        identity: RemoteMacIdentity,
        worktreePath: String,
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
                worktreePath: worktreePath,
                sessionName: sessionName
            )
            pendingPanesByAlias[alias] = nil
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
                    worktreePath: worktreePath,
                    nextPanes: &nextPanes
                ),
                right: promoteLayout(
                    right,
                    identity: identity,
                    worktreePath: worktreePath,
                    nextPanes: &nextPanes
                )
            )
        }
    }

    private func pruneExpiredPendingRoutes() {
        let cutoff = now()
        pendingPanesByAlias = pendingPanesByAlias.filter {
            $0.value.expiresAt > cutoff
        }
        pendingWorktreesByAlias = pendingWorktreesByAlias.filter {
            $0.value.expiresAt > cutoff
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
final class RelayedTerminalByteStream:
    GrafttyKit.TerminalByteStream,
    GrafttyKit.TerminalSizeReporting,
    @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>

    private let client: any WebSocketClient & Sendable
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var closed = false
    private var claimedControl = false
    private var ownershipSnapshot: DisplayOwnershipSnapshot?
    private var latestPTYSize: (cols: UInt16, rows: UInt16)?
    private var ptySizeHandler: ((_ cols: UInt16, _ rows: UInt16) -> Void)?
    private var cols = 80
    private var rows = 24
    private let displayClientID = DisplayClientID(UUID().uuidString)

    var onPTYSize: ((_ cols: UInt16, _ rows: UInt16) -> Void)? {
        get { lock.withLock { ptySizeHandler } }
        set {
            let currentSize = lock.withLock {
                ptySizeHandler = newValue
                return latestPTYSize
            }
            if let newValue, let currentSize {
                newValue(currentSize.cols, currentSize.rows)
            }
        }
    }

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
                    case .text(let text):
                        self.handleTextFrame(text)
                    case .binary:
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
                ownerEpoch: isOwnerLocked
                    ? ownershipSnapshot?.epoch
                    : nil,
                authoritativeSize: latestPTYSize,
                sizeHandler: ptySizeHandler
            )
        }
        guard state.isOpen else { return }
        if client.supportsWebControlTextFrames {
            if let ownerEpoch = state.ownerEpoch {
                await client.ownerResize(
                    clientID: displayClientID,
                    epoch: ownerEpoch,
                    cols: cols,
                    rows: rows
                )
            } else if let size = state.authoritativeSize {
                // The outer session accepted the follower's window-change
                // before this adapter could reject it. Reassert the actual
                // downstream owner's grid even when it has not changed.
                state.sizeHandler?(size.cols, size.rows)
            }
        } else {
            await client.resize(cols: cols, rows: rows)
        }
    }

    private var isOwnerLocked: Bool {
        ownershipSnapshot?.ownerClientID == displayClientID
            && ownershipSnapshot?.ownerKind == .mac
    }

    private func handleTextFrame(_ text: String) {
        guard let envelope = try? WebControlEnvelope.parse(Data(text.utf8))
        else { return }
        switch envelope {
        case .ownership(let snapshot):
            handleOwnershipSnapshot(snapshot)
        case .grid(let cols, let rows):
            reportPTYSize(cols: cols, rows: rows)
        case .resize, .hello, .takeControl, .ownerResize:
            break
        }
    }

    private func handleOwnershipSnapshot(
        _ snapshot: DisplayOwnershipSnapshot
    ) {
        let callback: ((_ cols: UInt16, _ rows: UInt16) -> Void)? =
            lock.withLock {
            if let previous = ownershipSnapshot,
               (snapshot.epoch < previous.epoch
                    || (snapshot.epoch == previous.epoch
                        && snapshot.revision < previous.revision)) {
                return nil
            }
            ownershipSnapshot = snapshot
            claimedControl = snapshot.ownerClientID == displayClientID
                && snapshot.ownerKind == .mac
            let size = (snapshot.grid.cols, snapshot.grid.rows)
            let changed = latestPTYSize?.cols != size.0
                || latestPTYSize?.rows != size.1
            latestPTYSize = size
            return changed ? ptySizeHandler : nil
        }
        callback?(snapshot.grid.cols, snapshot.grid.rows)
    }

    private func reportPTYSize(cols: UInt16, rows: UInt16) {
        let callback: ((_ cols: UInt16, _ rows: UInt16) -> Void)? =
            lock.withLock {
            let changed = latestPTYSize?.cols != cols
                || latestPTYSize?.rows != rows
            latestPTYSize = (cols, rows)
            return changed ? ptySizeHandler : nil
        }
        callback?(cols, rows)
    }

    func close() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard !closed else { return nil }
            closed = true
            ptySizeHandler = nil
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
