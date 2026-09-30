import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
@MainActor
struct PanePreviewClientPoolTests {

    final class FakePreviewClient: PanePreviewClienting {
        let sessionName: String
        var startCount = 0
        var suspendCount = 0
        var resumeCount = 0
        var stopCount = 0

        init(sessionName: String) {
            self.sessionName = sessionName
        }

        func start() { startCount += 1 }
        func suspend() { suspendCount += 1 }
        func resume() { resumeCount += 1 }
        func stop() { stopCount += 1 }
    }

    @Test
    func updateStartsOnlyCappedPreviewClientsAndStopsRemovedClients() {
        var made: [FakePreviewClient] = []
        let pool = PanePreviewClientPool { sessionName in
            let client = FakePreviewClient(sessionName: sessionName)
            made.append(client)
            return client
        }

        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "left", title: "Left", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .split(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(sessionName: "top", title: "Top", attentionText: nil, isBusy: false, attentionSource: nil),
                right: .leaf(sessionName: "bottom", title: "Bottom", attentionText: nil, isBusy: false, attentionSource: nil)
            )
        )

        pool.update(layout: layout, maxLivePreviews: 2)

        #expect(made.map(\.sessionName) == ["left", "top"])
        #expect(made.allSatisfy { $0.startCount == 1 })

        pool.update(layout: .leaf(sessionName: "top", title: "Top", attentionText: nil, isBusy: false, attentionSource: nil), maxLivePreviews: 2)

        #expect(made.first { $0.sessionName == "top" }?.stopCount == 0)
        #expect(made.first { $0.sessionName == "left" }?.stopCount == 1)
        #expect(made.first { $0.sessionName == "bottom" } == nil)
    }

    @Test
    func stopAllStopsEveryActiveClient() {
        var made: [FakePreviewClient] = []
        let pool = PanePreviewClientPool { sessionName in
            let client = FakePreviewClient(sessionName: sessionName)
            made.append(client)
            return client
        }

        pool.update(layout: .split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "one", title: "", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "two", title: "", attentionText: nil, isBusy: false, attentionSource: nil)
        ))

        pool.stopAll()

        #expect(made.map(\.stopCount) == [1, 1])
    }

    @Test("background suspension preserves preview client identity")
    func suspendAndResumeAllPreservesEveryClient() {
        var made: [FakePreviewClient] = []
        let pool = PanePreviewClientPool { sessionName in
            let client = FakePreviewClient(sessionName: sessionName)
            made.append(client)
            return client
        }

        pool.update(layout: .split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "one", title: "", attentionText: nil, isBusy: false, attentionSource: nil),
            right: .leaf(sessionName: "two", title: "", attentionText: nil, isBusy: false, attentionSource: nil)
        ))
        let identitiesBefore = pool.clients.mapValues(ObjectIdentifier.init)

        pool.suspendAll()
        pool.resumeAll()

        #expect(pool.clients.mapValues(ObjectIdentifier.init) == identitiesBefore)
        #expect(made.map(\.suspendCount) == [1, 1])
        #expect(made.map(\.resumeCount) == [1, 1])
        #expect(made.map(\.stopCount) == [0, 0])
    }
}

@Suite("Retained interactive pane connections")
@MainActor
struct RetainedPaneClientPoolTests {
    typealias Client = PanePreviewClientPoolTests.FakePreviewClient

    @Test("@spec IOS-7.9: While mobile remains in the foreground, switching compact pane views shall retain up to four recently visited pane connections and their existing leadership, reusing connections on return and releasing the least recently visited connection when the limit is exceeded.")
    func switchingReusesConnectionsAndEvictsLeastRecentlyUsed() {
        let pool = RetainedPaneClientPool<Client>(capacity: 2)
        let host = UUID()
        let a = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "a")
        let b = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "b")
        let c = RetainedPaneClientPool<Client>.Key(hostID: host, sessionName: "c")
        let first = pool.acquire(a) { Client(sessionName: "a") }
        let second = pool.acquire(b) { Client(sessionName: "b") }
        let revisited = pool.acquire(a) { Client(sessionName: "a") }
        #expect(revisited === first)
        #expect(first.startCount == 1)
        #expect(first.stopCount == 0)
        _ = pool.acquire(c) { Client(sessionName: "c") }
        #expect(second.stopCount == 1)
        #expect(first.stopCount == 0)
        pool.stopAll()
        #expect(first.stopCount == 1)
    }

    @Test("Retained panes are host scoped and all suspend on background")
    func hostIdentityAndSuspension() {
        let pool = RetainedPaneClientPool<Client>()
        let a = RetainedPaneClientPool<Client>.Key(hostID: UUID(), sessionName: "same")
        let b = RetainedPaneClientPool<Client>.Key(hostID: UUID(), sessionName: "same")
        let first = pool.acquire(a) { Client(sessionName: "same") }
        let second = pool.acquire(b) { Client(sessionName: "same") }
        #expect(first !== second)
        pool.suspendAll()
        #expect(first.suspendCount == 1)
        #expect(second.suspendCount == 1)
        #expect(pool.acquire(a) { Client(sessionName: "same") } === first)
        #expect(first.resumeCount == 1)
        pool.remove(a)
        #expect(first.stopCount == 1)
        #expect(second.stopCount == 0)
    }
}
