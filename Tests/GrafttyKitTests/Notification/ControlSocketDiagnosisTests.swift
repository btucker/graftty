import Testing
import Foundation
import Darwin
@testable import GrafttyKit

@Suite("ControlSocketDiagnosis")
struct ControlSocketDiagnosisTests {

    @Test("""
    @spec ATTN-3.4: If the control socket file exists on disk but `connect()` fails with `ECONNREFUSED`, then the CLI shall print "Graftty is running but not listening on `<path>`. Quit and relaunch Graftty to reset the control socket." and exit with code 1, rather than conflating this stale-listener case with `ATTN-3.1`'s "not running" message. The conditions differ: `ENOENT` (file missing) means the app never created the socket, whereas `ECONNREFUSED` on an existing file means a prior Graftty instance crashed without unlinking, or its `SocketServer.start()` failed after the file was created but before listening began.
    """)
    func classifiesConnectRefusedWithExistingFileAsStale() {
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
