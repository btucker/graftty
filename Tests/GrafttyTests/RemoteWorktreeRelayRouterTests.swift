import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("Remote worktree one-hop relay")
@MainActor
struct RemoteWorktreeRelayRouterTests {
    @Test("""
    @spec REMOTE-13.1: While a Mac shares worktrees from a directly connected \
    Remote Mac, the application shall preserve the remote split layout, replace \
    resource identifiers with opaque one-hop aliases, and exclude any row that \
    was already relayed by the downstream Mac.
    """)
    func promotesOnlyDirectRowsAndPreservesLayout() throws {
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        let router = RemoteWorktreeRelayRouter()
        let directLayout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.37,
            left: .leaf(
                sessionName: "left-pane",
                title: "editor",
                attentionText: nil,
                isBusy: false,
                attentionSource: nil
            ),
            right: .split(
                direction: .vertical,
                ratio: 0.61,
                left: .leaf(
                    sessionName: "top-pane",
                    title: "tests",
                    attentionText: nil,
                    isBusy: true,
                    attentionSource: nil
                ),
                right: .leaf(
                    sessionName: "bottom-pane",
                    title: "agent",
                    attentionText: "Claude needs input",
                    isBusy: false,
                    attentionSource: .agentStop
                )
            )
        )
        let direct = worktree(
            path: "/repos/one/.worktrees/feature",
            repositoryID: "/repos/one",
            layout: directLayout,
            attentionText: "Claude needs input",
            attentionSource: .agentStop,
            origin: WorktreeOrigin(
                deviceID: remote.id,
                deviceLabel: remote.label,
                relayDepth: 0
            )
        )
        let alreadyRelayed = worktree(
            path: "relay-worktree-from-elsewhere",
            repositoryID: "relay-repository-from-elsewhere",
            layout: directLayout,
            origin: WorktreeOrigin(
                deviceID: RemoteDeviceID(value: "third-mac"),
                deviceLabel: "Third Mac",
                relayDepth: 1
            )
        )

        let promoted = router.promotedWorktrees(
            snapshots: [identity: [direct, alreadyRelayed]],
            remoteMacs: [remote]
        )

        let row = try #require(promoted.first)
        #expect(promoted.count == 1)
        #expect(row.path.hasPrefix("relay-worktree-"))
        #expect(row.repositoryID?.hasPrefix("relay-repository-") == true)
        #expect(row.route?.worktreeID == row.path)
        #expect(row.route?.repositoryID == row.repositoryID)
        #expect(row.origin?.relayDepth == 1)
        #expect(row.attentionSource == .agentStop)
        #expect(row.layout?.leaves.map(\.title) == ["editor", "tests", "agent"])

        guard case let .split(direction, ratio, _, right)? = row.layout else {
            Issue.record("expected the outer split to be preserved")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.37)
        guard case let .split(nestedDirection, nestedRatio, _, _) = right else {
            Issue.record("expected the nested split to be preserved")
            return
        }
        #expect(nestedDirection == .vertical)
        #expect(nestedRatio == 0.61)

        let paneAliases = try #require(row.layout?.leaves)
        #expect(paneAliases.allSatisfy {
            $0.sessionName.hasPrefix("relay-pane-")
        })
        #expect(
            router.resolvePane(paneAliases[0].sessionName)
                == RelayedPaneTarget(
                    identity: identity,
                    worktreePath: direct.path,
                    sessionName: "left-pane"
                )
        )
        #expect(
            router.resolveWorktree(row.path)
                == RelayedWorktreeTarget(
                    identity: identity,
                    path: direct.path
                )
        )
    }

    @Test("""
    @spec REMOTE-13.2: When GrafttyMobile connects to a Mac that has a live \
    direct Remote Mac connection, the application shall expose that Remote \
    Mac's repositories and worktrees as depth-one rows whose repository \
    aliases match across listing and creation routes.
    """)
    func repositoryAndWorktreeAliasesMatch() throws {
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        let router = RemoteWorktreeRelayRouter()
        let row = worktree(
            path: "/repos/one/.worktrees/feature",
            repositoryID: "/repos/one",
            layout: nil,
            origin: nil
        )
        let promotedWorktree = try #require(
            router.promotedWorktrees(
                snapshots: [identity: [row]],
                remoteMacs: [remote]
            ).first
        )
        let repository = RemoteRepositoryInfo(
            id: "/repos/one",
            displayName: "one",
            origin: nil,
            defaultBranchStatus: nil,
            branches: [
                .init(
                    name: "feature",
                    source: .local,
                    lastCommitDate: Date(timeIntervalSince1970: 1),
                    mountedWorktreeID:
                        "/repos/one/.worktrees/feature",
                    pullRequest: nil
                ),
            ]
        )
        let promotedRepository = try #require(
            router.promotedRepositories(
                [repository],
                from: remote
            ).first
        )

        #expect(promotedWorktree.repositoryID == promotedRepository.id)
        #expect(promotedWorktree.route?.repositoryID == promotedRepository.id)
        #expect(
            router.resolveRepository(promotedRepository.id)
                == RelayedRepositoryTarget(
                    identity: identity,
                    repositoryID: repository.id
                )
        )
        let mountedID = try #require(
            promotedRepository.branches.first?.mountedWorktreeID
        )
        #expect(mountedID.hasPrefix("relay-worktree-"))
        #expect(!mountedID.contains("/repos/"))
        #expect(
            router.resolveWorktree(mountedID)
                == RelayedWorktreeTarget(
                    identity: identity,
                    path: "/repos/one/.worktrees/feature"
                )
        )
    }

    @Test
    func newlyCreatedAliasesSurviveOneStaleSnapshot() throws {
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        let router = RemoteWorktreeRelayRouter()
        let created = router.registerCreatedWorktree(
            identity: identity,
            path: "/repos/one/.worktrees/new-feature",
            paneSessionName: "new-feature-pane"
        )

        _ = router.promotedWorktrees(
            snapshots: [identity: []],
            remoteMacs: [remote]
        )

        #expect(
            router.resolveWorktree(created.worktreeID)?.path
                == "/repos/one/.worktrees/new-feature"
        )
        #expect(
            router.resolvePane(created.paneID)?.sessionName
                == "new-feature-pane"
        )
    }

    @Test
    func repositoryRefreshRemovesObsoleteMountedWorktreeRoute() throws {
        let remote = try makeRemoteMac()
        let router = RemoteWorktreeRelayRouter()
        let mountedPath = "/repos/one/.worktrees/feature"
        let repository = RemoteRepositoryInfo(
            id: "/repos/one",
            displayName: "one",
            origin: nil,
            defaultBranchStatus: nil,
            branches: [
                .init(
                    name: "feature",
                    source: .local,
                    lastCommitDate: Date(timeIntervalSince1970: 1),
                    mountedWorktreeID: mountedPath,
                    pullRequest: nil
                ),
            ]
        )
        let promoted = try #require(
            router.promotedRepositories([repository], from: remote).first
        )
        let mountedAlias = try #require(
            promoted.branches.first?.mountedWorktreeID
        )
        #expect(router.resolveWorktree(mountedAlias)?.path == mountedPath)

        _ = router.promotedRepositories(
            [
                RemoteRepositoryInfo(
                    id: repository.id,
                    displayName: repository.displayName,
                    origin: nil,
                    defaultBranchStatus: nil,
                    branches: []
                ),
            ],
            from: remote
        )

        #expect(router.resolveWorktree(mountedAlias) == nil)
    }

    @Test("""
    @spec REMOTE-13.19: While GrafttyMobile views a relayed terminal, opening \
    or resizing the follower shall not steal downstream display ownership; \
    input shall claim ownership when needed, ownership loss shall permit a \
    later reclaim, and the downstream owner's authoritative grid shall be \
    reported back through the outer session.
    """)
    func relayedTerminalMirrorsOwnershipAndAuthoritativeGrid() async throws {
        let client = RelayWebSocketClient()
        let stream = RelayedTerminalByteStream(client: client)
        let sizes = LockedRelaySizes()
        stream.onPTYSize = { sizes.append(cols: $0, rows: $1) }

        try await waitUntil { client.helloClientID() != nil }
        let owningMac = DisplayClientID("owning-mac")
        client.deliver(.text(try ownershipFrame(
            owner: owningMac,
            cols: 200,
            rows: 50,
            epoch: 1
        )))
        try await waitUntil { sizes.values().count == 1 }

        // A follower window-change is rejected downstream and the outer
        // session is immediately corrected back to the owner's grid.
        await stream.resize(cols: 80, rows: 24)
        try await waitUntil { sizes.values().count == 2 }
        #expect(sizes.values() == [
            RelaySize(cols: 200, rows: 50),
            RelaySize(cols: 200, rows: 50),
        ])
        #expect(client.takeControls().isEmpty)

        try await stream.send(Data("first".utf8))
        try await waitUntil { client.takeControls().count == 1 }
        let relayID = try #require(client.takeControls().first?.clientID)
        client.deliver(.text(try ownershipFrame(
            owner: relayID,
            cols: 80,
            rows: 24,
            epoch: 2
        )))
        try await waitUntil { sizes.values().count == 3 }

        await stream.resize(cols: 100, rows: 30)
        try await waitUntil { client.ownerResizes().count == 1 }
        #expect(client.ownerResizes().first?.epoch == 2)

        client.deliver(.text(try ownershipFrame(
            owner: owningMac,
            cols: 200,
            rows: 50,
            epoch: 3
        )))
        try await waitUntil { sizes.values().count == 4 }
        try await stream.send(Data("second".utf8))
        try await waitUntil { client.takeControls().count == 2 }

        await stream.close()
    }

    @Test("""
    @spec REMOTE-13.4: When a user selects a Remote Mac worktree, the \
    application shall project the entire remote split tree with the original \
    axes and ratios, rather than opening only the selected pane.
    """)
    func detailProjectionPreservesFullSplitTree() {
        let first = PaneSlotID()
        let second = PaneSlotID()
        let third = PaneSlotID()
        let slots = [
            "one": first,
            "two": second,
            "three": third,
        ]
        let layout = PaneLayoutNode.split(
            direction: .vertical,
            ratio: 0.4,
            left: .leaf(
                sessionName: "one",
                title: "one",
                attentionText: nil,
                isBusy: false,
                attentionSource: nil
            ),
            right: .split(
                direction: .horizontal,
                ratio: 0.7,
                left: .leaf(
                    sessionName: "two",
                    title: "two",
                    attentionText: nil,
                    isBusy: false,
                    attentionSource: nil
                ),
                right: .leaf(
                    sessionName: "three",
                    title: "three",
                    attentionText: nil,
                    isBusy: false,
                    attentionSource: nil
                )
            )
        )

        let projected = SplitTree(root: RemotePaneLayoutProjection.node(
            from: layout,
            slotForSession: { slots[$0]! }
        ))

        #expect(projected.allLeaves == [first, second, third])
        guard case let .split(outer)? = projected.root else {
            Issue.record("expected outer split")
            return
        }
        #expect(outer.direction == .vertical)
        #expect(outer.ratio == 0.4)
        guard case let .split(inner) = outer.right else {
            Issue.record("expected inner split")
            return
        }
        #expect(inner.direction == .horizontal)
        #expect(inner.ratio == 0.7)
    }

    private func makeRemoteMac() throws -> RemoteMac {
        RemoteMac(
            id: RemoteDeviceID(value: "studio-mac"),
            label: "Studio Mac",
            fingerprint: try RemoteIdentityFingerprint(
                rawBytes: Data(repeating: 0x41, count: 32)
            )
        )
    }

    private func worktree(
        path: String,
        repositoryID: String,
        layout: PaneLayoutNode?,
        attentionText: String? = nil,
        attentionSource: AttentionSource? = nil,
        origin: WorktreeOrigin?
    ) -> WorktreePanes {
        WorktreePanes(
            path: path,
            displayName: "feature",
            repoDisplayName: "one",
            repositoryID: repositoryID,
            displayBranch: "feature",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: attentionText,
            attentionSource: attentionSource,
            layout: layout,
            origin: origin
        )
    }
}

private struct RelaySize: Equatable {
    let cols: UInt16
    let rows: UInt16
}

private final class LockedRelaySizes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RelaySize] = []

    func append(cols: UInt16, rows: UInt16) {
        lock.withLock {
            storage.append(RelaySize(cols: cols, rows: rows))
        }
    }

    func values() -> [RelaySize] {
        lock.withLock { storage }
    }
}

private struct RelayTakeControl {
    let clientID: DisplayClientID
}

private struct RelayOwnerResize {
    let epoch: UInt64
}

private final class RelayWebSocketClient:
    WebSocketClient,
    @unchecked Sendable {
    let supportsWebControlTextFrames = true
    private let lock = NSLock()
    private var frames: [WebSocketFrame] = []
    private var receiveWaiters:
        [CheckedContinuation<WebSocketFrame, Error>] = []
    private var helloID: DisplayClientID?
    private var recordedTakeControls: [RelayTakeControl] = []
    private var recordedOwnerResizes: [RelayOwnerResize] = []

    func send(_ frame: WebSocketFrame) async throws {}

    func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            let frame = lock.withLock { () -> WebSocketFrame? in
                guard frames.isEmpty else { return frames.removeFirst() }
                receiveWaiters.append(continuation)
                return nil
            }
            if let frame {
                continuation.resume(returning: frame)
            }
        }
    }

    func close() {
        let waiters = lock.withLock {
            let waiters = receiveWaiters
            receiveWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }

    func sendHello(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        cols: Int,
        rows: Int
    ) async {
        lock.withLock { helloID = clientID }
    }

    func takeControl(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        cols: Int,
        rows: Int
    ) async {
        lock.withLock {
            recordedTakeControls.append(
                RelayTakeControl(clientID: clientID)
            )
        }
    }

    func ownerResize(
        clientID: DisplayClientID,
        epoch: UInt64,
        cols: Int,
        rows: Int
    ) async {
        lock.withLock {
            recordedOwnerResizes.append(RelayOwnerResize(epoch: epoch))
        }
    }

    func deliver(_ frame: WebSocketFrame) {
        let waiter = lock.withLock {
            guard !receiveWaiters.isEmpty else {
                frames.append(frame)
                return Optional<
                    CheckedContinuation<WebSocketFrame, Error>
                >.none
            }
            return receiveWaiters.removeFirst()
        }
        waiter?.resume(returning: frame)
    }

    func helloClientID() -> DisplayClientID? {
        lock.withLock { helloID }
    }

    func takeControls() -> [RelayTakeControl] {
        lock.withLock { recordedTakeControls }
    }

    func ownerResizes() -> [RelayOwnerResize] {
        lock.withLock { recordedOwnerResizes }
    }
}

private func ownershipFrame(
    owner: DisplayClientID,
    cols: UInt16,
    rows: UInt16,
    epoch: UInt64
) throws -> String {
    WebControlEnvelope.ownership(
        try DisplayOwnershipSnapshot(
            sessionName: "session",
            ownerClientID: owner,
            ownerKind: .mac,
            grid: DisplayGrid(cols: cols, rows: rows),
            epoch: epoch,
            revision: epoch
        )
    ).encoded()
}

private func waitUntil(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw RelayWaitTimeout()
}

private struct RelayWaitTimeout: Error {}
