import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("Pane subscription renewal lifecycle", .timeLimit(.minutes(1)))
struct PanesStateRenewalLifecycleTests {
    @Test("@spec REMOTE-6.17: When a panes-state subscription is replaced, the client shall fence snapshots and close callbacks from earlier generations so they cannot overwrite or close the replacement.")
    func lateOldCallbacksCannotReachReplacement() async throws {
        let old = RenewalDriver(rows: [row("old")])
        let fresh = RenewalDriver(rows: [row("fresh")])
        let host = RenewalHost([old, fresh])
        let renewal = ManualReplyDeadline()
        let store = try await PanesStateSubscription.open(on: host, health: .init(renewal: renewal.deadline))
        var frames = store.frameUpdates().makeAsyncIterator()
        #expect(await frames.next() == .snapshot([row("old")]))
        await renewal.waitUntilArmed()
        renewal.fire()
        #expect(await frames.next() == .snapshot([row("fresh")]))
        await old.deliver([row("late-old")])
        await old.closed("late-close")
        #expect(await store.current == [row("fresh")])
        #expect(await store.connectionState == .subscribed)
        // An equal initial snapshot still counts as a successful renewal.
        await fresh.deliver([row("fresh")])
        #expect(await frames.next() == .snapshot([row("fresh")]))
        await store.unsubscribe()
    }

    @Test("@spec REMOTE-6.18: If a pane subscription is cancelled, manually unsubscribed, or released by its last owner, then the client shall cancel renewal and snapshot waits and close its host subscription without reconnecting or reporting a new failure.")
    func unsubscribeAndReleaseCancelMaintenance() async throws {
        let driver = RenewalDriver(rows: [])
        let host = RenewalHost([driver])
        let renewal = ManualReplyDeadline()
        let closed = RequestCounter()
        var store: WorktreePanesStore? = try await PanesStateSubscription.open(
            on: host, health: .init(renewal: renewal.deadline), onClosed: { _ in closed.increment() })
        #expect(try await store?.waitForFirstSnapshot(timeout: .seconds(2)) == .received)
        await renewal.waitUntilArmed()
        await store?.unsubscribe()
        #expect(driver.closeCount == 1)
        #expect(await eventually { !renewal.isArmed })
        renewal.fire()
        #expect(await host.requested == [true])
        #expect(closed.count == 0)
        store = nil

        let releasedDriver = RenewalDriver(rows: [])
        let releasedHost = RenewalHost([releasedDriver])
        let releasedRenewal = ManualReplyDeadline()
        var released: WorktreePanesStore? = try await PanesStateSubscription.open(
            on: releasedHost, health: .init(renewal: releasedRenewal.deadline), onClosed: { _ in closed.increment() })
        #expect(try await released?.waitForFirstSnapshot(timeout: .seconds(2)) == .received)
        await releasedRenewal.waitUntilArmed()
        released = nil
        #expect(await eventually { releasedDriver.closeCount == 1 && !releasedRenewal.isArmed })
        #expect(closed.count == 0)
    }

    @Test("cancelling an opening subscription closes its partial channel")
    func cancelDuringInitialOpen() async throws {
        let driver = RenewalDriver(rows: [], script: .wait)
        let host = RenewalHost([driver])
        let attempt = Task { try await PanesStateSubscription.open(on: host) }
        #expect(await eventually { driver.openCount == 1 })
        attempt.cancel()
        await #expect(throws: CancellationError.self) { _ = try await attempt.value }
        #expect(driver.closeCount == 1)
        #expect(await host.requested == [true])
    }

    @Test("a renewal deadline covers a peer that never acknowledges the new subsystem")
    func renewalOpenDeadlineIsEndToEnd() async throws {
        let old = RenewalDriver(rows: [])
        let stuck = RenewalDriver(rows: [], script: .wait)
        let host = RenewalHost([old, stuck])
        let renewal = ManualReplyDeadline()
        let initial = ManualReplyDeadline()
        let (closes, closed) = AsyncStream<String>.makeStream()
        let store = try await PanesStateSubscription.open(
            on: host, health: .init(renewal: renewal.deadline, initialSnapshot: initial.deadline),
            onClosed: { closed.yield($0) })
        #expect(try await store.waitForFirstSnapshot(timeout: .seconds(2)) == .received)
        await renewal.waitUntilArmed()
        renewal.fire()
        #expect(await eventually { stuck.openCount == 1 && initial.isArmed })
        initial.fire()
        var iterator = closes.makeAsyncIterator()
        #expect(await iterator.next() == "panes-state initial snapshot timed out")
        #expect(old.closeCount == 1)
        #expect(stuck.closeCount == 1)
        #expect(await store.connectionState == .closed(reason: "panes-state initial snapshot timed out"))
        #expect(await host.requested == [true, true])
        await store.unsubscribe()
    }

    @Test("a renewal open error closes the observable feed instead of retaining healthy stale rows")
    func renewalFailureEndsFeed() async throws {
        let host = RenewalHost([RenewalDriver(rows: []), RenewalDriver(rows: [], script: .fail)])
        let renewal = ManualReplyDeadline()
        let store = try await PanesStateSubscription.open(on: host, health: .init(renewal: renewal.deadline))
        var frames = store.frameUpdates().makeAsyncIterator()
        #expect(await frames.next() == .snapshot([]))
        await renewal.waitUntilArmed()
        renewal.fire()
        #expect(await frames.next() == nil)
        if case .closed = await store.connectionState {} else { Issue.record("failed renewal stayed healthy") }
        await store.unsubscribe()
    }

    private func row(_ name: String) -> WorktreePanes {
        WorktreePanes(path: "/\(name)", displayName: name, repoDisplayName: "repo", displayBranch: name,
                      state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < end { await Task.yield() }
        return condition()
    }
}

private actor RenewalHost: PanesStateDriverMaking {
    let drivers: [RenewalDriver]
    private(set) var requested: [Bool] = []
    init(_ drivers: [RenewalDriver]) { self.drivers = drivers }
    func makePanesStateDriver(originAware: Bool) throws -> any PanesStateSubscriptionDriver {
        let index = requested.count
        requested.append(originAware)
        guard index < drivers.count else { throw RenewalDriver.Failure.injected }
        return drivers[index]
    }
}

private final class RenewalDriver: PanesStateSubscriptionDriver, @unchecked Sendable {
    enum Script { case send, wait, fail }
    enum Failure: Error { case injected }
    let rows: [WorktreePanes]
    let script: Script
    private let lock = NSLock()
    private var snapshot: PanesStateChannelClient.OnSnapshot = { _ in }
    private var closeCallback: PanesStateChannelClient.OnClosed = { _ in }
    private var opens = 0
    private var closes = 0
    var openCount: Int { lock.withLock { opens } }
    var closeCount: Int { lock.withLock { closes } }
    init(rows: [WorktreePanes], script: Script = .send) { self.rows = rows; self.script = script }
    func setCallbacks(onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
                      onClosed: @escaping PanesStateChannelClient.OnClosed) {
        lock.withLock { snapshot = onSnapshot; closeCallback = onClosed }
    }
    func open() async throws {
        lock.withLock { opens += 1 }
        switch script {
        case .send: await deliver(rows)
        case .fail: throw Failure.injected
        case .wait:
            let (stream, _) = AsyncStream<Void>.makeStream()
            for await _ in stream {}
            try Task.checkCancellation()
        }
    }
    func close() { lock.withLock { closes += 1 } }
    func deliver(_ rows: [WorktreePanes]) async { await lock.withLock { snapshot }(rows) }
    func closed(_ reason: String) async { await lock.withLock { closeCallback }(reason) }
}
