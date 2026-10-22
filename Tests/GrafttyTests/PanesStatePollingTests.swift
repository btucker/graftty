import GrafttyProtocol
import Testing
@testable import Graftty

@Suite("Panes-state polling")
struct PanesStatePollingTests {
    private static let a = PanesStateMessage.snapshot([])
    private static let b = PanesStateMessage.snapshot([], sidebar: SidebarSnapshot(projects: []))
    private static let c = PanesStateMessage.snapshot(
        [], sidebar: SidebarSnapshot(projects: [], supportsNavigationEditing: false)
    )

    @Test("Sends the initial snapshot, then only snapshots that changed, and stops reading after cancel")
    func sendsInitialThenChangesOnly() async throws {
        // The test changes the snapshot only after checking what was sent,
        // so a slow scheduler cannot let a later snapshot through early.
        let source = await SnapshotSource(Self.a)
        let received = Received()
        let subscription = await PanesStatePolling.subscribe(
            interval: .milliseconds(5),
            snapshot: { source.next() },
            onChange: { await received.append($0) }
        )
        defer { subscription.cancel() }
        #expect(await received.messages == [Self.a])

        // An unchanged snapshot is read again but not sent again.
        try await waitUntil { await source.reads >= 3 }
        #expect(await received.messages == [Self.a])

        await source.set(Self.b)
        try await waitUntil { await received.messages.count >= 2 }
        let readsAfterB = await source.reads
        try await waitUntil { await source.reads >= readsAfterB + 2 }
        #expect(await received.messages == [Self.a, Self.b])

        await source.set(Self.c)
        try await waitUntil { await received.messages.count >= 3 }
        #expect(await received.messages == [Self.a, Self.b, Self.c])

        subscription.cancel()
        let readsAtCancel = await source.reads
        try await Task.sleep(for: .milliseconds(100))
        // A read already waiting for the main actor may still finish.
        #expect(await source.reads <= readsAtCancel + 1)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the polling loop")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class SnapshotSource {
    private var current: PanesStateMessage
    private(set) var reads = 0

    init(_ initial: PanesStateMessage) { current = initial }

    func set(_ message: PanesStateMessage) { current = message }

    func next() -> PanesStateMessage {
        reads += 1
        return current
    }
}

private actor Received {
    private(set) var messages: [PanesStateMessage] = []
    func append(_ message: PanesStateMessage) { messages.append(message) }
}
