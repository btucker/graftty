import Foundation
import os
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("WorktreePanesStore — channel-driver-backed façade.")
struct WorktreePanesStoreTests {
    @Test("@spec REMOTE-14.8: When sidebar metadata arrives before its worktree callback is applied, the application shall retain the previous complete snapshot and reject navigation reconciliation against rows from a different snapshot.")
    func sidebarMetadataWaitsForMatchingRows() async throws {
        let driver = MetadataChannelDriver()
        let store = WorktreePanesStore(driver: driver)
        let old = SidebarSnapshot(projects: [])
        driver.sidebarSnapshot = old
        await store.applySnapshot([])
        let next = SidebarSnapshot(projects: [.init(id: "p", repositoryID: "/repo", name: "Project")])
        // The channel decoder receives a frame before its asynchronous
        // callback reaches the store. Readers must still see the old pair.
        driver.sidebarSnapshot = next
        #expect(await store.sidebar == old)
        #expect(await store.currentSnapshot == .snapshot([], sidebar: old))
        let rows = makeWorktrees(count: 1)
        await store.applySnapshot(rows)
        #expect(await store.sidebar == next)
        #expect(await store.navigationSnapshot(matching: []) == nil)
        #expect(await store.navigationSnapshot(matching: rows) == .snapshot(rows, sidebar: next))
        driver.sidebarSnapshot = nil
        await store.applySnapshot([])
        #expect(await store.navigationSnapshot(matching: []) == .snapshot([]))
    }

    @Test func subscribeOpensDriverAndUpdatesState() async throws {
        let driver = FakeChannelDriver()
        let store = WorktreePanesStore(driver: driver)
        try await store.subscribe()
        #expect(await store.connectionState == .subscribed)
        #expect(driver.opened)
    }

    @Test func applySnapshotMutatesCurrent() async throws {
        let driver = FakeChannelDriver()
        let store = WorktreePanesStore(driver: driver)
        let snapshot = makeWorktrees(count: 2)
        await store.applySnapshot(snapshot)
        #expect(await store.current == snapshot)
    }

    @Test func unsubscribeClosesDriverAndUpdatesState() async throws {
        let driver = FakeChannelDriver()
        let store = WorktreePanesStore(driver: driver)
        try await store.subscribe()
        await store.unsubscribe()
        #expect(await store.connectionState == .closed(reason: "unsubscribed"))
        #expect(driver.closed)
    }

    @Test func markClosedUpdatesState() async throws {
        let driver = FakeChannelDriver()
        let store = WorktreePanesStore(driver: driver)
        await store.markClosed(reason: "network-error")
        #expect(await store.connectionState == .closed(reason: "network-error"))
    }

    @Test func closeDuringOpenCannotBeOverwrittenAsSubscribed() async throws {
        let driver = ClosingDuringOpenDriver()
        let store = WorktreePanesStore(driver: driver)
        driver.onOpen = {
            await store.markClosed(reason: "closed-during-open")
        }

        await #expect(throws: WorktreePanesStore.SubscriptionError.closedDuringOpen(
            reason: "closed-during-open"
        )) {
            try await store.subscribe()
        }
        #expect(
            await store.connectionState
                == .closed(reason: "closed-during-open")
        )
        #expect(driver.closed)
    }

    private func makeWorktrees(count: Int) -> [WorktreePanes] {
        (0..<count).map { idx in
            WorktreePanes(
                path: "/repo/wt-\(idx)",
                displayName: "wt-\(idx)",
                repoDisplayName: "graftty",
                displayBranch: "branch-\(idx)",
                state: .running,
                isMainCheckout: false,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil, isBusy: false, attentionSource: nil)
            )
        }
    }
}

@Suite("@spec REMOTE-6.7: While a client waits for the first panes-state snapshot, it shall resume as soon as a snapshot or channel close is applied, report a close ahead of a snapshot, and report a timeout only when the deadline fires first.")
struct FirstSnapshotWaitTests {
    @Test func resumesWhenSnapshotArrives() async throws {
        let store = WorktreePanesStore(driver: FakeChannelDriver())
        let deadline = ManualReplyDeadline()
        let wait = Task { try await store.waitForFirstSnapshot(deadline: deadline.deadline) }
        await deadline.waitUntilArmed()

        await store.applySnapshot([])

        #expect(try await wait.value == .received)
        #expect(!deadline.isArmed)
    }

    @Test func resumesWhenChannelCloses() async throws {
        let store = WorktreePanesStore(driver: FakeChannelDriver())
        let deadline = ManualReplyDeadline()
        let wait = Task { try await store.waitForFirstSnapshot(deadline: deadline.deadline) }
        await deadline.waitUntilArmed()

        await store.markClosed(reason: "network-error")

        #expect(try await wait.value == .closed)
        #expect(!deadline.isArmed)
    }

    @Test func reportsCloseAheadOfSnapshot() async throws {
        let store = WorktreePanesStore(driver: FakeChannelDriver())
        await store.applySnapshot([])
        await store.unsubscribe()

        #expect(try await store.waitForFirstSnapshot(deadline: ManualReplyDeadline().deadline) == .closed)
    }

    @Test func returnsImmediatelyForAnAlreadyAppliedSnapshot() async throws {
        let store = WorktreePanesStore(driver: FakeChannelDriver())
        await store.applySnapshot([])

        #expect(try await store.waitForFirstSnapshot(deadline: ManualReplyDeadline().deadline) == .received)
    }

    @Test func timesOutWhenDeadlineFiresFirst() async throws {
        let store = WorktreePanesStore(driver: FakeChannelDriver())
        let deadline = ManualReplyDeadline()
        let wait = Task { try await store.waitForFirstSnapshot(deadline: deadline.deadline) }
        await deadline.waitUntilArmed()

        deadline.fire()

        #expect(try await wait.value == .timedOut)
    }

    @Test func cancellationThrowsAndDisarmsDeadline() async throws {
        let store = WorktreePanesStore(driver: FakeChannelDriver())
        let deadline = ManualReplyDeadline()
        let wait = Task { try await store.waitForFirstSnapshot(deadline: deadline.deadline) }
        await deadline.waitUntilArmed()

        wait.cancel()

        await #expect(throws: CancellationError.self) { try await wait.value }
        #expect(!deadline.isArmed)
    }
}

private final class ClosingDuringOpenDriver:
    PanesStateChannelDriver,
    @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(
        initialState: (
            onOpen: Optional<@Sendable () async -> Void>.none,
            closed: false
        )
    )

    var onOpen: (@Sendable () async -> Void)? {
        get { lock.withLock { $0.onOpen } }
        set { lock.withLock { $0.onOpen = newValue } }
    }

    var closed: Bool { lock.withLock { $0.closed } }

    func open() async throws {
        let callback = lock.withLock { $0.onOpen }
        await callback?()
    }

    func close() {
        lock.withLock { $0.closed = true }
    }
}

private final class MetadataChannelDriver: PanesStateChannelDriver, SidebarSnapshotProviding, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Optional<SidebarSnapshot>.none)
    var sidebarSnapshot: SidebarSnapshot? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
    func open() async throws {}
    func close() {}
}

private final class FakeChannelDriver: PanesStateChannelDriver, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (opened: false, closed: false))

    var opened: Bool { lock.withLock { $0.opened } }
    var closed: Bool { lock.withLock { $0.closed } }

    func open() async throws {
        lock.withLock { $0.opened = true }
    }

    func close() {
        lock.withLock { $0.closed = true }
    }
}
