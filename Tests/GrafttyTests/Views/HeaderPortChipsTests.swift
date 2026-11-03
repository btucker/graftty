import Testing
import GrafttyProtocol
@testable import Graftty

@Suite("@spec PORTS-3.1: While the selected worktree's panes listen on ports, the application shall show one chip per port in the header, covering every pane, and collapse extras into a menu.")
struct HeaderPortChipsTests {
    private func binding(_ port: Int) -> PortBinding {
        PortBinding(port: UInt16(port), scope: .loopback, processName: "node", pid: 1)
    }
    @Test func headerChipsCoverEveryPane() {
        let chips = HeaderPortChips(entries: [.init(binding: binding(3000), session: "a"), .init(binding: binding(5173), session: "b")])
        #expect(chips.visible.map(\.binding.port) == [3000, 5173])
        #expect(chips.overflow.isEmpty)
    }
    @Test func samePortIsOneChipSortedByPort() {
        let chips = HeaderPortChips(entries: [.init(binding: binding(5173), session: "b"), .init(binding: binding(3000), session: "a"), .init(binding: binding(3000), session: "b")])
        #expect(chips.visible.map(\.binding.port) == [3000, 5173])
    }
    @Test func extraChipsCollapse() {
        let chips = HeaderPortChips(entries: [3000, 3001, 3002, 3003].map { .init(binding: binding($0), session: "a") })
        #expect(chips.visible.count == 2)
        #expect(chips.overflow.map(\.binding.port) == [3002, 3003])
    }
}
