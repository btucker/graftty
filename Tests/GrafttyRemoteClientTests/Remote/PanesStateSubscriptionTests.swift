import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("PanesStateSubscription — shared V2→V1 panes-state negotiation")
struct PanesStateSubscriptionTests {
    @Test("@spec REMOTE-6.8: When a host rejects the origin-aware panes-state-v2 subsystem, the client shall open the V1 panes-state subsystem on the same connection and deliver its snapshots to the store and the owner.")
    func rejectedV2FallsBackToV1() async throws {
        let v2 = ScriptedPanesDriver(open: .fail(PanesStateChannelClient.ClientError.openFailed(
            PanesStateChannelClient.ClientError.subsystemRejected)))
        let v1 = ScriptedPanesDriver(open: .succeed)
        let host = ScriptedPanesHost(v2: v2, v1: v1)
        let owner = OwnerRecorder()

        let store = try await PanesStateSubscription.open(
            on: host, onSnapshot: owner.snapshot, onClosed: owner.closed)

        #expect(await host.requested == [true, false])
        #expect(await store.connectionState == .subscribed)
        #expect(v2.closeCount == 1)
        let rows = [WorktreePanes(
            path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
            state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: nil)]
        await v1.deliver(rows)
        #expect(await store.current == rows)
        #expect(owner.snapshots == [rows])
    }

    @Test("@spec REMOTE-6.9: If opening the panes-state-v2 subsystem fails for any reason other than the host rejecting it, then the client shall report that failure without opening the V1 subsystem.")
    func nonRejectionFailureDoesNotFallBack() async throws {
        let v2 = ScriptedPanesDriver(open: .fail(PanesStateChannelClient.ClientError.openFailed(
            PanesStateChannelClient.ClientError.timedOut)))
        let host = ScriptedPanesHost(v2: v2, v1: ScriptedPanesDriver(open: .succeed))

        await #expect(throws: PanesStateChannelClient.ClientError.self) {
            _ = try await PanesStateSubscription.open(on: host)
        }
        #expect(await host.requested == [true])
        #expect(v2.closeCount == 1)
    }

    @Test("@spec REMOTE-6.10: If the panes-state channel closes before its open completes, then the client shall fail the subscription without opening another subsystem or reporting the close or any later snapshot to the owner, and shall report closes after a completed open to the owner.")
    func closeDuringOpenFailsWithoutReachingOwner() async throws {
        let v2 = ScriptedPanesDriver(open: .closeDuringOpen("dropped"))
        let host = ScriptedPanesHost(v2: v2, v1: ScriptedPanesDriver(open: .succeed))
        let owner = OwnerRecorder()

        await #expect(throws: WorktreePanesStore.SubscriptionError.closedDuringOpen(reason: "dropped")) {
            _ = try await PanesStateSubscription.open(
                on: host, onSnapshot: owner.snapshot, onClosed: owner.closed)
        }
        #expect(await host.requested == [true])
        #expect(owner.closes.isEmpty)
        // A frame the failed channel buffered before its close still drains.
        await v2.deliver([])
        #expect(owner.snapshots.isEmpty)

        let live = ScriptedPanesDriver(open: .succeed)
        let store = try await PanesStateSubscription.open(
            on: ScriptedPanesHost(v2: live, v1: ScriptedPanesDriver(open: .succeed)),
            onSnapshot: owner.snapshot, onClosed: owner.closed)
        await live.closeFromPeer("peer-gone")
        #expect(await store.connectionState == .closed(reason: "peer-gone"))
        #expect(owner.closes == ["peer-gone"])
    }

    @Test("@spec REMOTE-6.11: If the task opening a panes-state subscription is cancelled when the host rejects panes-state-v2, then the client shall stop without opening the V1 subsystem.")
    func cancelledAttemptDoesNotFallBack() async throws {
        let v2 = ScriptedPanesDriver(open: .cancelThenFail(PanesStateChannelClient.ClientError.openFailed(
            PanesStateChannelClient.ClientError.subsystemRejected)))
        let host = ScriptedPanesHost(v2: v2, v1: ScriptedPanesDriver(open: .succeed))

        let attempt = Task { try await PanesStateSubscription.open(on: host) }
        await #expect(throws: CancellationError.self) {
            _ = try await attempt.value
        }
        #expect(await host.requested == [true])
    }
}

private actor ScriptedPanesHost: PanesStateDriverMaking {
    private let v2: ScriptedPanesDriver
    private let v1: ScriptedPanesDriver
    private(set) var requested: [Bool] = []

    init(v2: ScriptedPanesDriver, v1: ScriptedPanesDriver) {
        self.v2 = v2
        self.v1 = v1
    }

    func makePanesStateDriver(originAware: Bool) -> any PanesStateSubscriptionDriver {
        requested.append(originAware)
        return originAware ? v2 : v1
    }
}

private final class ScriptedPanesDriver: PanesStateSubscriptionDriver, @unchecked Sendable {
    enum OpenScript {
        case succeed
        case fail(any Error)
        case closeDuringOpen(String)
        /// Cancels the opening task, as a superseded attempt would be, then fails.
        case cancelThenFail(any Error)
    }

    private let lock = NSLock()
    private let script: OpenScript
    private var onSnapshot: PanesStateChannelClient.OnSnapshot = { _ in }
    private var onClosed: PanesStateChannelClient.OnClosed = { _ in }
    private var closes = 0

    init(open script: OpenScript) {
        self.script = script
    }

    var closeCount: Int { lock.withLock { closes } }

    func setCallbacks(
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        onClosed: @escaping PanesStateChannelClient.OnClosed
    ) {
        lock.withLock {
            self.onSnapshot = onSnapshot
            self.onClosed = onClosed
        }
    }

    func open() async throws {
        switch script {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .closeDuringOpen(let reason):
            await closeFromPeer(reason)
        case .cancelThenFail(let error):
            withUnsafeCurrentTask { $0?.cancel() }
            throw error
        }
    }

    func close() {
        lock.withLock { closes += 1 }
    }

    func deliver(_ rows: [WorktreePanes]) async {
        await lock.withLock { onSnapshot }(rows)
    }

    func closeFromPeer(_ reason: String) async {
        await lock.withLock { onClosed }(reason)
    }
}

private final class OwnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotStorage: [[WorktreePanes]] = []
    private var closeStorage: [String] = []

    var snapshots: [[WorktreePanes]] { lock.withLock { snapshotStorage } }
    var closes: [String] { lock.withLock { closeStorage } }

    var snapshot: PanesStateChannelClient.OnSnapshot {
        { [self] rows in lock.withLock { snapshotStorage.append(rows) } }
    }

    var closed: PanesStateChannelClient.OnClosed {
        { [self] reason in lock.withLock { closeStorage.append(reason) } }
    }
}
