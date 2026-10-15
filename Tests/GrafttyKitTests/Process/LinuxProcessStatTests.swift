import Foundation
import Testing
@testable import GrafttyKit

struct LinuxProcessStatTests {
    @Test("@spec REMOTE-23.1: When reading Linux process identity, the application shall parse process names containing spaces and closing parentheses without shifting the parent PID or start time fields.")
    func parsesProcStat() throws {
        let fields = ["S", "41", "42", "43", "34817"]
            + Array(repeating: "0", count: 14) + ["123456"]
        let value = try #require(LinuxProcessStat("42 (agent (worker) name) " + fields.joined(separator: " ")))
        #expect(value.pid == 42)
        #expect(value.parentPID == 41)
        #expect(value.terminalDevice == 34817)
        #expect(value.startTicks == 123456)
    }

    @Test("@spec REMOTE-23.2: If Linux process metadata is missing or malformed, then the application shall report no process identity.")
    func rejectsMalformedStat() {
        for value in ["", "42 worker S 1", "42 (worker) S 1", "-1 (worker) S 1"] {
            #expect(LinuxProcessStat(value) == nil)
        }
    }

    @Test("@spec REMOTE-23.3: When querying a running host process, the application shall return a stable start identity, its parent PID, and its current working directory.")
    func readsOwnProcess() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let identity = try #require(ProcessIdentityReader.startTimeMicroseconds(ofPID: pid))
        #expect(ProcessIdentityReader.startTimeMicroseconds(ofPID: pid) == identity)
        #expect(ProcessAncestryReader.entry(forPID: pid)?.parentPID == getppid())
        #expect(PIDCwdReader.cwd(ofPID: pid) == FileManager.default.currentDirectoryPath)
        #expect(ProcessIdentityReader.startTimeMicroseconds(ofPID: Int32.max) == nil)
    }
}
