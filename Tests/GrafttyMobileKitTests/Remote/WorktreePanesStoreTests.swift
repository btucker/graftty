#if canImport(UIKit)
import Foundation
import os
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("WorktreePanesStore — channel-driver-backed façade.")
struct WorktreePanesStoreTests {

    @Test func subscribeOpensDriverAndUpdatesState() async throws {
        let driver = FakeChannelDriver()
        let store = WorktreePanesStore(driver: driver)
        try await store.subscribe()
        #expect(await store.connectionState == .subscribed)
        #expect(await driver.opened == true)
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
        #expect(await driver.closed == true)
    }

    @Test func markClosedUpdatesState() async throws {
        let driver = FakeChannelDriver()
        let store = WorktreePanesStore(driver: driver)
        await store.markClosed(reason: "network-error")
        #expect(await store.connectionState == .closed(reason: "network-error"))
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
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil, isBusy: false)
            )
        }
    }
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
#endif
