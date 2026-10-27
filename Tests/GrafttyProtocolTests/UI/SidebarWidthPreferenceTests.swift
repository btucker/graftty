import Testing
import SwiftUI
@testable import GrafttyProtocol

@Suite("SidebarWidthKey + persistSidebarWidth — shared sidebar width plumbing")
struct SidebarWidthPreferenceTests {

    @Test("reduce ignores zero candidates")
    func reduceIgnoresZero() {
        var value: Double = 240
        SidebarWidthKey.reduce(value: &value, nextValue: { 0 })
        #expect(value == 240)
    }

    @Test("reduce accepts non-zero candidates")
    func reduceAcceptsNonZero() {
        var value: Double = 240
        SidebarWidthKey.reduce(value: &value, nextValue: { 360 })
        #expect(value == 360)
    }

    @Test("reduce default value is zero")
    func defaultIsZero() {
        #expect(SidebarWidthKey.defaultValue == 0)
    }

    @Test("the timed debounce writes later, and never runs a superseded write")
    @MainActor
    func timedDebounceRunsOnlyUncancelledWritesLater() async throws {
        var writes: [Int] = []
        let debounce = SidebarWidthDebounce.after(.zero)
        let cancel = debounce.schedule { writes.append(1) }
        cancel()
        _ = debounce.schedule { writes.append(2) }
        #expect(writes.isEmpty)
        let deadline = ContinuousClock.now + .seconds(5)
        while writes.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(writes == [2])
    }
}
