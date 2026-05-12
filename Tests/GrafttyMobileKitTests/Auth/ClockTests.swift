#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct ClockTests {
    @Test
    func systemClockSleepResolvesAfterRequestedInterval() async throws {
        let clock = SystemClock()
        let start = clock.now
        try await clock.sleep(for: 0.05)
        let elapsed = clock.now.timeIntervalSince(start)
        #expect(elapsed >= 0.04)  // small jitter tolerance
    }
}
#endif
