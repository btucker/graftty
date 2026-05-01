import Testing
@testable import GrafttyKit

@Suite("""
PTY device availability
@spec ZMX-5.3: Before creating a new terminal surface, the application shall probe whether the OS can allocate, grant, and unlock a PTY. If that probe fails, the application shall skip surface creation for that pane and log the failure rather than calling into libghostty and relying on a lower-level resource-exhaustion failure. This guard is best-effort and race-prone by nature, but it gives Graftty a controlled failure path when the system PTY pool is exhausted.
""")
struct PtyDeviceAvailabilityTests {

    @Test func availableWhenProbeOpensAndClosesPTY() {
        var closedFD: Int32?

        let availability = PtyDeviceAvailability.probe(
            openPTY: { 42 },
            grantPTY: { _ in 0 },
            unlockPTY: { _ in 0 },
            closeFD: { closedFD = $0 }
        )

        #expect(availability == .available)
        #expect(closedFD == 42)
    }

    @Test func exhaustedWhenOpenPTYFails() {
        let availability = PtyDeviceAvailability.probe(
            openPTY: { -1 },
            grantPTY: { _ in Issue.record("should not grant an invalid fd"); return -1 },
            unlockPTY: { _ in Issue.record("should not unlock an invalid fd"); return -1 },
            closeFD: { _ in Issue.record("should not close an invalid fd") }
        )

        #expect(availability == .unavailable)
    }

    @Test func unavailableWhenGrantFailsAndClosesPTY() {
        var closedFD: Int32?

        let availability = PtyDeviceAvailability.probe(
            openPTY: { 42 },
            grantPTY: { _ in -1 },
            unlockPTY: { _ in Issue.record("should not unlock when grant failed"); return -1 },
            closeFD: { closedFD = $0 }
        )

        #expect(availability == .unavailable)
        #expect(closedFD == 42)
    }

    @Test func unavailableWhenUnlockFailsAndClosesPTY() {
        var closedFD: Int32?

        let availability = PtyDeviceAvailability.probe(
            openPTY: { 42 },
            grantPTY: { _ in 0 },
            unlockPTY: { _ in -1 },
            closeFD: { closedFD = $0 }
        )

        #expect(availability == .unavailable)
        #expect(closedFD == 42)
    }
}
