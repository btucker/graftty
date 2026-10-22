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
        let source = await SnapshotSource([Self.a, Self.a, Self.b, Self.b, Self.c])
        let received = Received()
        let subscription = await PanesStatePolling.subscribe(
            interval: .milliseconds(5),
            snapshot: { source.next() },
            onChange: { await received.append($0) }
        )
        #expect(await received.messages == [Self.a])

        let deadline = ContinuousClock.now + .seconds(5)
        while await received.messages.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await received.messages == [Self.a, Self.b, Self.c])

        subscription.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let readsAfterCancel = await source.reads
        try await Task.sleep(for: .milliseconds(50))
        #expect(await source.reads == readsAfterCancel)
    }
}

@MainActor
private final class SnapshotSource {
    private var remaining: [PanesStateMessage]
    private(set) var reads = 0

    init(_ messages: [PanesStateMessage]) { remaining = messages }

    /// Returns the queued snapshots in order, then repeats the last one.
    func next() -> PanesStateMessage {
        reads += 1
        return remaining.count > 1 ? remaining.removeFirst() : remaining[0]
    }
}

private actor Received {
    private(set) var messages: [PanesStateMessage] = []
    func append(_ message: PanesStateMessage) { messages.append(message) }
}
