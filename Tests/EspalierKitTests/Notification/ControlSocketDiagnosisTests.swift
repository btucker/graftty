import Testing
import Foundation
import Darwin
@testable import EspalierKit

@Suite("ControlSocketDiagnosis")
struct ControlSocketDiagnosisTests {

    @Test func classifiesConnectRefusedWithExistingFileAsStale() {
        let reason = ControlSocketDiagnosis.classifyConnectFailure(
            errno: ECONNREFUSED,
            socketExists: true,
            path: "/tmp/s"
        )
        #expect(reason == .staleSocket(path: "/tmp/s"))
    }

    @Test func classifiesEnoentAsNotRunning() {
        let reason = ControlSocketDiagnosis.classifyConnectFailure(
            errno: ENOENT,
            socketExists: false,
            path: "/tmp/s"
        )
        #expect(reason == .notRunning)
    }

    @Test func classifiesConnectRefusedWithNoFileAsNotRunning() {
        // The socket file was removed between our fileExists check and
        // connect() — rare TOCTOU path, but "not running" is still the
        // honest answer since there's nothing to reconnect to.
        let reason = ControlSocketDiagnosis.classifyConnectFailure(
            errno: ECONNREFUSED,
            socketExists: false,
            path: "/tmp/s"
        )
        #expect(reason == .notRunning)
    }

    @Test func classifiesOtherErrnoAsTimeout() {
        let reason = ControlSocketDiagnosis.classifyConnectFailure(
            errno: ETIMEDOUT,
            socketExists: true,
            path: "/tmp/s"
        )
        #expect(reason == .timeout)
    }
}
