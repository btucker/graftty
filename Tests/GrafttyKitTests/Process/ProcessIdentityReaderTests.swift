import Foundation
import Testing
@testable import GrafttyKit

@Suite("ProcessIdentityReader — process start identity")
struct ProcessIdentityReaderTests {
    @Test("Current process start time is positive and no later than now.")
    func readsCurrentProcessStartTime() throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let startTime = try #require(ProcessIdentityReader.startTimeMicroseconds(ofPID: ownPID))
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)

        #expect(startTime > 0)
        #expect(startTime <= now)
    }

    @Test("Missing PID returns nil.")
    func returnsNilForMissingPID() {
        #expect(ProcessIdentityReader.startTimeMicroseconds(ofPID: 0) == nil)
    }

    @Test("Microsecond conversion preserves the subsecond component exactly.")
    func microsecondsConversionPreservesSubsecondComponentExactly() {
        #expect(ProcessIdentityReader.microseconds(seconds: 1_700_000_123, microseconds: 456_789) == 1_700_000_123_456_789)
    }
}
