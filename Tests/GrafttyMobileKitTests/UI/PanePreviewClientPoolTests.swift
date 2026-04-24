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
        var stopCount = 0

        init(sessionName: String) {
            self.sessionName = sessionName
        }

        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    @Test
    func updateStartsOneClientForEachLeafAndStopsRemovedClients() {
        var made: [FakePreviewClient] = []
        let pool = PanePreviewClientPool { sessionName in
            let client = FakePreviewClient(sessionName: sessionName)
            made.append(client)
            return client
        }

        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "left", title: "Left"),
            right: .split(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(sessionName: "top", title: "Top"),
                right: .leaf(sessionName: "bottom", title: "Bottom")
            )
        )

        pool.update(layout: layout)

        #expect(made.map(\.sessionName).sorted() == ["bottom", "left", "top"])
        #expect(made.allSatisfy { $0.startCount == 1 })

        pool.update(layout: .leaf(sessionName: "top", title: "Top"))

        #expect(made.first { $0.sessionName == "top" }?.stopCount == 0)
        #expect(made.first { $0.sessionName == "left" }?.stopCount == 1)
        #expect(made.first { $0.sessionName == "bottom" }?.stopCount == 1)
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
            left: .leaf(sessionName: "one", title: ""),
            right: .leaf(sessionName: "two", title: "")
        ))

        pool.stopAll()

        #expect(made.map(\.stopCount) == [1, 1])
    }
}
