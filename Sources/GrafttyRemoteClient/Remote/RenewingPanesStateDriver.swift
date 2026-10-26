import Foundation
import GrafttyProtocol
import NIOConcurrencyHelpers

/// Keeps one observable store across pane-only channel renewals. Each generation
/// has its own store and queue. Its drain must finish before the next generation
/// can publish, so late frames and closes cannot affect the replacement.
final class RenewingPanesStateDriver: PanesStateSubscriptionDriver, SidebarSnapshotProviding, @unchecked Sendable {
    typealias MakeFeed = @Sendable (AsyncStream<PanesStateMessage>.Continuation) async throws -> WorktreePanesStore

    private struct Feed: Sendable {
        let store: WorktreePanesStore
        let frames: AsyncStream<PanesStateMessage>
    }

    private enum Outcome: Sendable { case renew, ended, cancelled }
    private enum HealthError: Error { case renewalDue, initialSnapshotTimedOut, channelClosed }

    private let health: PanesStateHealthPolicy
    private let makeFeed: MakeFeed
    private let lock = NIOLock()
    private var started = false
    private var stopped = false
    private var task: Task<Void, Never>?
    private var activeStore: WorktreePanesStore?
    private var onSnapshot: PanesStateChannelClient.OnSnapshot = { _ in }
    private var onClosed: PanesStateChannelClient.OnClosed = { _ in }
    private var sidebar: SidebarSnapshot?

    var sidebarSnapshot: SidebarSnapshot? { lock.withLock { sidebar } }

    init(health: PanesStateHealthPolicy, makeFeed: @escaping MakeFeed) {
        self.health = health
        self.makeFeed = makeFeed
    }

    func setCallbacks(onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
                      onClosed: @escaping PanesStateChannelClient.OnClosed) {
        lock.withLock { self.onSnapshot = onSnapshot; self.onClosed = onClosed }
    }

    func open() async throws {
        try lock.withLock {
            guard !started, !stopped else { throw PanesStateChannelClient.ClientError.channelClosed }
            started = true
        }
        let feed = try await createFeed()
        do { try Task.checkCancellation() }
        catch { await feed.store.unsubscribe(); throw error }
        let accepted = lock.withLock {
            guard !stopped else { return false }
            task = Task { await self.run(feed) }
            return true
        }
        if !accepted {
            await feed.store.unsubscribe()
            throw PanesStateChannelClient.ClientError.channelClosed
        }
    }

    func close() {
        let task = lock.withLock {
            stopped = true
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }

    func shutdown() async {
        close()
        let store = lock.withLock { activeStore }
        await store?.unsubscribe()
    }

    private func createFeed() async throws -> Feed {
        let (frames, continuation) = AsyncStream<PanesStateMessage>.makeStream()
        do {
            let store = try await makeFeed(continuation)
            let accepted = lock.withLock {
                guard !stopped, !Task.isCancelled else { return false }
                activeStore = store
                return true
            }
            guard accepted else { await store.unsubscribe(); throw CancellationError() }
            return Feed(store: store, frames: frames)
        } catch { continuation.finish(); throw error }
    }

    private func run(_ initial: Feed) async {
        var feed = initial
        do {
            switch try await feed.store.waitForFirstSnapshot(deadline: health.initialSnapshot) {
            case .received: break
            case .closed: throw HealthError.channelClosed
            case .timedOut: throw HealthError.initialSnapshotTimedOut
            }
            while !Task.isCancelled {
                let outcome = await relayUntilRenewal(feed)
                // The old drain has finished, including any awaited owner
                // callback. Close its channel before installing another.
                await feed.store.unsubscribe()
                try Task.checkCancellation()
                guard case .renew = outcome else { throw HealthError.channelClosed }
                feed = try await renewedFeed()
            }
            await feed.store.unsubscribe()
        } catch {
            // A replacement may have opened just as its deadline won. It
            // may not yet be assigned to `feed`, but still needs teardown.
            let active = lock.withLock { activeStore }
            await active?.unsubscribe()
            if !Task.isCancelled { await fail(error) }
        }
    }

    private func relayUntilRenewal(_ feed: Feed) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await frame in feed.frames {
                    guard !Task.isCancelled else { return .cancelled }
                    switch frame {
                    case .snapshot(let rows, let sidebar):
                        let callback = self.lock.withLock { () -> PanesStateChannelClient.OnSnapshot? in
                            guard !self.stopped else { return nil }
                            self.sidebar = sidebar
                            return self.onSnapshot
                        }
                        guard let callback else { return .cancelled }
                        await callback(rows)
                    }
                }
                return .ended
            }
            group.addTask {
                do {
                    try await SSHReplyWaiter<Void>().wait(
                        scheduleTimeout: self.health.renewal.schedule,
                        timeoutError: HealthError.renewalDue, onAbort: {}, start: {})
                    return .renew
                } catch HealthError.renewalDue { return .renew }
                catch { return .cancelled }
            }
            let outcome = await group.next() ?? .cancelled
            group.cancelAll()
            return outcome
        }
    }

    /// One deadline covers replacement channel creation, V2→V1 negotiation,
    /// and its first snapshot. Thus a previously healthy feed converges or
    /// fails within 60 + 15 seconds of its previous fresh initial snapshot,
    /// including channel creation and negotiation. Uses Swift's clock, including over WebRTC.
    private func renewedFeed() async throws -> Feed {
        try await withThrowingTaskGroup(of: Feed.self) { group in
            group.addTask {
                let feed = try await self.createFeed()
                do {
                    // The sibling owns the end-to-end deadline. This wait
                    // only needs snapshot, close, and cancellation signals.
                    let outcome = try await feed.store.waitForFirstSnapshot(deadline: ReplyDeadline { _ in {} })
                    try Task.checkCancellation()
                    guard outcome == .received else { throw HealthError.channelClosed }
                    return feed
                } catch {
                    await feed.store.unsubscribe()
                    throw error
                }
            }
            group.addTask {
                try await SSHReplyWaiter<Feed>().wait(
                    scheduleTimeout: self.health.initialSnapshot.schedule,
                    timeoutError: HealthError.initialSnapshotTimedOut, onAbort: {}, start: {})
            }
            defer { group.cancelAll() }
            guard let feed = try await group.next() else { throw HealthError.channelClosed }
            return feed
        }
    }

    private func fail(_ error: any Error) async {
        let callback = lock.withLock { () -> PanesStateChannelClient.OnClosed? in
            guard !stopped else { return nil }
            stopped = true
            task = nil
            return onClosed
        }
        let reason: String
        switch error {
        case HealthError.initialSnapshotTimedOut: reason = "panes-state initial snapshot timed out"
        case HealthError.channelClosed: reason = "panes-state channel closed"
        default: reason = "panes-state renewal failed: \(error)"
        }
        await callback?(reason)
    }
}
