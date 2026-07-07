#if canImport(UIKit)
import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyMobileKit

@MainActor
@Suite("WorktreeListContent — extracted picker preserves callbacks + onListChanged")
struct WorktreeListContentTests {

    private func sampleHost() -> Host {
        Host(
            id: UUID(),
            label: "test",
            baseURL: URL(string: "https://test.local")!,
            addedAt: Date(),
            lastUsedAt: nil
        )
    }

    @Test("init stores host and three callbacks; onListChanged defaults to no-op")
    func initStoresCallbacks() {
        let h = sampleHost()
        let view = WorktreeListContent(
            host: h,
            onSelect: { _ in },
            onSelectPane: { _ in }
        )
        #expect(view.host.id == h.id)
        // No-op default doesn't crash when invoked.
        view.onListChanged([])
    }

    @Test("custom onListChanged is invoked with the supplied list")
    func customOnListChanged() {
        var received: [WorktreePanes]?
        let view = WorktreeListContent(
            host: sampleHost(),
            onSelect: { _ in },
            onSelectPane: { _ in },
            onListChanged: { list in received = list }
        )
        view.onListChanged([])
        #expect(received != nil && received?.isEmpty == true)
    }

    @Test("WorktreePickerView wrapper delegates to WorktreeListContent")
    func wrapperDelegates() {
        let h = sampleHost()
        let wrapper = WorktreePickerView(
            host: h,
            onSelect: { _ in },
            onSelectPane: { _ in }
        )
        #expect(wrapper.host.id == h.id)
    }

    @Test("""
@spec IPAD-1.19: iPad sidebar worktree rows shall use a tight trailing inset so git divergence stats sit near the sidebar edge.
""")
    func tightTrailingInset() {
        #expect(WorktreeListContent.iPadRowTrailingInset <= 4)
    }
}
#endif
