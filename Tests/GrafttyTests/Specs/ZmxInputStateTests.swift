import Testing
import Foundation
@testable import GrafttyKit

@Suite("ZmxInputState — typed-but-uncommitted byte tracking")
struct ZmxInputStateTests {
    @Test("New session starts with zero uncommitted bytes.")
    func startsClean() {
        let state = ZmxInputState()
        #expect(state.uncommittedBytes(forSession: "s1") == 0)
    }

    @Test("Bytes accumulate until a CR/LF is observed, then reset.")
    func resetOnNewline() {
        let state = ZmxInputState()
        state.recordInput("hello".data(using: .utf8)!, forSession: "s1")
        #expect(state.uncommittedBytes(forSession: "s1") == 5)

        state.recordInput("\r".data(using: .utf8)!, forSession: "s1")
        #expect(state.uncommittedBytes(forSession: "s1") == 0)
    }

    @Test("LF also commits.")
    func lfCommits() {
        let state = ZmxInputState()
        state.recordInput("foo".data(using: .utf8)!, forSession: "s1")
        state.recordInput("\n".data(using: .utf8)!, forSession: "s1")
        #expect(state.uncommittedBytes(forSession: "s1") == 0)
    }

    @Test("Bytes after a newline are tracked anew.")
    func resumesAfterCommit() {
        let state = ZmxInputState()
        state.recordInput("ab\rcd".data(using: .utf8)!, forSession: "s1")
        #expect(state.uncommittedBytes(forSession: "s1") == 2)
    }

    @Test("Sessions are tracked independently.")
    func sessionsIndependent() {
        let state = ZmxInputState()
        state.recordInput("xx".data(using: .utf8)!, forSession: "a")
        state.recordInput("yyyy".data(using: .utf8)!, forSession: "b")
        #expect(state.uncommittedBytes(forSession: "a") == 2)
        #expect(state.uncommittedBytes(forSession: "b") == 4)
    }

    @Test("Removing a session zeroes its tracking.")
    func removeSession() {
        let state = ZmxInputState()
        state.recordInput("xx".data(using: .utf8)!, forSession: "a")
        state.removeSession("a")
        #expect(state.uncommittedBytes(forSession: "a") == 0)
    }
}
