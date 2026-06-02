#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite
@MainActor
struct PreviewPoolTests {

    final class StubPreview: PanePreviewClienting {
        let sessionName: String
        var started = false
        init(sessionName: String) { self.sessionName = sessionName }
        func start() { started = true }
        func stop() { started = false }
    }

    private static let threeLeaves = PaneLayoutNode.split(
        direction: .horizontal,
        ratio: 0.5,
        left: .leaf(sessionName: "a", title: "A", attentionText: nil, isBusy: false),
        right: .split(
            direction: .vertical,
            ratio: 0.5,
            left: .leaf(sessionName: "b", title: "B", attentionText: nil, isBusy: false),
            right: .leaf(sessionName: "c", title: "C", attentionText: nil, isBusy: false)
        )
    )

    @Test("""
@spec IOS-10.2: When `WorktreeDetailView` is active with a multi-leaf layout, the application shall create a live preview `SessionClient` for every leaf so each pane tile renders a real-time preview rather than a static title.
""")
    func poolCreatesOnePreviewPerLeafByDefault() {
        let pool = PanePreviewClientPool { sessionName in
            StubPreview(sessionName: sessionName)
        }
        pool.update(layout: Self.threeLeaves)
        #expect(pool.clients.count == 3)
        #expect(pool.clients["a"]?.started == true)
        #expect(pool.clients["b"]?.started == true)
        #expect(pool.clients["c"]?.started == true)
    }

    @Test
    func poolRespectsExplicitCapForCallersThatStillNeedOne() {
        let pool = PanePreviewClientPool { sessionName in
            StubPreview(sessionName: sessionName)
        }
        pool.update(layout: Self.threeLeaves, maxLivePreviews: 1)
        #expect(pool.clients.count == 1)
        #expect(pool.clients["a"]?.started == true)
    }
}
#endif
