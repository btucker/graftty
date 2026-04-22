#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
@MainActor
struct BiometricGateTests {

    final class FakeClock: Clock, @unchecked Sendable {
        var now: Date
        init(_ start: Date) { self.now = start }
    }

    final class FakeAuthenticator: BiometricAuthenticator, @unchecked Sendable {
        var outcome: Result<Void, Error> = .success(())
        var callCount = 0
        func authenticate() async -> Result<Void, Error> {
            callCount += 1
            return outcome
        }
    }

    @Test
    func coldLaunchStartsLocked() {
        let gate = BiometricGate(clock: FakeClock(Date()), authenticator: FakeAuthenticator())
        #expect(gate.state == .locked)
    }

    @Test
    func successfulAuthUnlocks() async {
        let auth = FakeAuthenticator()
        let gate = BiometricGate(clock: FakeClock(Date()), authenticator: auth)
        await gate.authenticate()
        #expect(gate.state == .unlocked)
        #expect(auth.callCount == 1)
    }

    @Test
    func backgroundForLessThanFiveMinutesStaysUnlocked() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let gate = BiometricGate(clock: clock, authenticator: FakeAuthenticator())
        await gate.authenticate()
        gate.applicationDidEnterBackground()
        clock.now = clock.now.addingTimeInterval(4 * 60)
        gate.applicationWillEnterForeground()
        #expect(gate.state == .unlocked)
    }

    @Test
    func backgroundForFiveOrMoreMinutesLocks() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_000))
        let gate = BiometricGate(clock: clock, authenticator: FakeAuthenticator())
        await gate.authenticate()
        gate.applicationDidEnterBackground()
        clock.now = clock.now.addingTimeInterval(5 * 60)
        gate.applicationWillEnterForeground()
        #expect(gate.state == .locked)
    }

    @Test
    func failedAuthStaysLocked() async {
        let auth = FakeAuthenticator()
        struct Denied: Error {}
        auth.outcome = .failure(Denied())
        let gate = BiometricGate(clock: FakeClock(Date()), authenticator: auth)
        await gate.authenticate()
        #expect(gate.state == .locked)
    }
}
#endif
