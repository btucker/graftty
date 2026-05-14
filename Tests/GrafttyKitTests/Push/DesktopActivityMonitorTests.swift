import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec PUSH-2.3: The application shall set `isUserActiveOnDesktop == true` iff the system is not sleeping, the screen is not locked, and `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .anyInputEventType) < 60`.
""")
struct DesktopActivityMonitorTests {
    @Test func activeWhenAwakeUnlockedAndRecentInput() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: false, lastInputAgeSeconds: 5)
        let m = DesktopActivityMonitor(source: src)
        #expect(m.isUserActiveOnDesktop == true)
    }

    @Test func inactiveWhenSleeping() {
        let src = MockDesktopActivitySource(systemAsleep: true, screenLocked: false, lastInputAgeSeconds: 1)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == false)
    }

    @Test func inactiveWhenScreenLocked() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: true, lastInputAgeSeconds: 1)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == false)
    }

    @Test func inactiveWhenIdleAtLeast60Seconds() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: false, lastInputAgeSeconds: 60)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == false)
    }

    @Test func activeAtBoundaryUnder60Seconds() {
        let src = MockDesktopActivitySource(systemAsleep: false, screenLocked: false, lastInputAgeSeconds: 59.999)
        #expect(DesktopActivityMonitor(source: src).isUserActiveOnDesktop == true)
    }
}

private final class MockDesktopActivitySource: DesktopActivitySource, @unchecked Sendable {
    var systemAsleep: Bool
    var screenLocked: Bool
    var lastInputAgeSeconds: TimeInterval
    init(systemAsleep: Bool, screenLocked: Bool, lastInputAgeSeconds: TimeInterval) {
        self.systemAsleep = systemAsleep
        self.screenLocked = screenLocked
        self.lastInputAgeSeconds = lastInputAgeSeconds
    }
}
