#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct ClockTests {
    @Test(.timeLimit(.minutes(1)))
    func virtualSleepRejectsCancellationBeforeRegistration() async throws {
        let clock = VirtualClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: 3)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.pendingSleepCount == 0)
    }

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
