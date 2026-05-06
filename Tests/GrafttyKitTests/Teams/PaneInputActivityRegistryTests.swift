import Foundation
import Testing
@testable import GrafttyKit

@Suite("PaneInputActivityRegistry — per-pane last-keystroke timestamp")
struct PaneInputActivityRegistryTests {
    @Test("Initial lookup is nil.")
    func initialNil() {
        let r = PaneInputActivityRegistry()
        #expect(r.lastInputAt(paneID: UUID()) == nil)
    }

    @Test("Recording returns the recorded timestamp.")
    func recordThenRead() {
        let pane = UUID()
        let clock = Clock(value: Date(timeIntervalSince1970: 1_000))
        let r = PaneInputActivityRegistry(now: { clock.value })
        r.recordKeystroke(paneID: pane)
        #expect(r.lastInputAt(paneID: pane) == Date(timeIntervalSince1970: 1_000))
        clock.value = Date(timeIntervalSince1970: 1_100)
        r.recordKeystroke(paneID: pane)
        #expect(r.lastInputAt(paneID: pane) == Date(timeIntervalSince1970: 1_100))
    }

    @Test("Distinct panes are independent.")
    func independentPanes() {
        let clock = Clock(value: Date(timeIntervalSince1970: 1_000))
        let r = PaneInputActivityRegistry(now: { clock.value })
        let a = UUID()
        let b = UUID()
        r.recordKeystroke(paneID: a)
        clock.value = Date(timeIntervalSince1970: 1_010)
        r.recordKeystroke(paneID: b)
        #expect(r.lastInputAt(paneID: a) == Date(timeIntervalSince1970: 1_000))
        #expect(r.lastInputAt(paneID: b) == Date(timeIntervalSince1970: 1_010))
    }

    @Test("removeStamp drops the entry, leaving lastInputAt nil for that pane.")
    func removeStampDropsEntry() {
        let pane = UUID()
        let r = PaneInputActivityRegistry(now: { Date(timeIntervalSince1970: 1_000) })
        r.recordKeystroke(paneID: pane)
        #expect(r.lastInputAt(paneID: pane) != nil)
        r.removeStamp(paneID: pane)
        #expect(r.lastInputAt(paneID: pane) == nil)
    }

    private final class Clock: @unchecked Sendable {
        var value: Date
        init(value: Date) { self.value = value }
    }
}
