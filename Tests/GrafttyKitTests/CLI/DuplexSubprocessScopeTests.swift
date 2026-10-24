import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DuplexSubprocessScopeTests {
    @Test("@spec REMOTE-30.21: When the parent app terminates, the application shall synchronously stop and reap its tracked MCP and provider proxy process groups and reject subprocess creation after shutdown.")
    func terminationClosesProcessesAndRejectsLateCreation() throws {
        let scope = DuplexSubprocessScope()
        let child = try scope.launch { try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:]) }
        scope.close()
        scope.close()
        #expect(kill(child.processID, 0) == -1 && errno == ESRCH)
        #expect(throws: CancellationError.self) {
            try scope.launch {
                Issue.record("Spawned after shutdown")
                return try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:])
            }
        }
    }
}
