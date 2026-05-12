#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite
@MainActor
struct PreviewCapTests {

    final class StubPreview: PanePreviewClienting {
        let sessionName: String
        var started = false
        init(sessionName: String) { self.sessionName = sessionName }
        func start() { started = true }
        func stop() { started = false }
    }

    @Test("""
@spec IOS-10.2: The `WorktreeDetailView` preview pool shall keep at most one live preview `SessionClient`.
""")
    func poolKeepsAtMostOneLivePreviewWhenCappedAtOne() {
        let pool = PanePreviewClientPool { sessionName in
            StubPreview(sessionName: sessionName)
        }
        let layout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.5,
            left: .leaf(sessionName: "a", title: "A", attentionText: nil),
            right: .split(
                direction: .vertical,
                ratio: 0.5,
                left: .leaf(sessionName: "b", title: "B", attentionText: nil),
                right: .leaf(sessionName: "c", title: "C", attentionText: nil)
            )
        )
        pool.update(layout: layout, maxLivePreviews: 1)
        #expect(pool.clients.count == 1)
        #expect(pool.clients["a"]?.started == true)
    }
}
#endif
