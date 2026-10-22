import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DuplexSubprocessTests {
    @Test("@spec REMOTE-26.23: When a provider proxy stops or fails, the application shall close its streams, stop its process group, and reap its child process, while retaining only bounded diagnostic output.")
    func duplexBytesAndCleanup() async throws {
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:])
        let pid = child.processID
        try child.input.write(contentsOf: Data("echo\n".utf8))
        #expect(try child.output.read(upToCount: 5) == Data("echo\n".utf8))
        await child.stop()
        await child.stop()
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func diagnosticsAreBoundedAndNoisyChildCannotBlock() async throws {
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 131072 /dev/zero >&2; printf ready; cat"], environment: ["PATH": "/usr/bin:/bin"])
        #expect(try child.output.read(upToCount: 5) == Data("ready".utf8))
        await child.stop()
        #expect(child.diagnostics.utf8.count <= 65536)
    }

    @Test func missingExecutableFailsWithoutLeakingDescriptors() throws {
        #expect(throws: (any Error).self) {
            _ = try DuplexSubprocess(executable: URL(fileURLWithPath: "/graftty-missing-proxy"), arguments: [], environment: [:])
        }
    }

    @Test(.timeLimit(.minutes(1))) func stopsDescendantsEvenAfterLeaderExits() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-descendant-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(sleep 1; touch \"$1\") & printf ready", "proxy", marker.path],
            environment: ["PATH": "/usr/bin:/bin"])
        #expect(try child.output.read(upToCount: 5) == Data("ready".utf8))
        await child.stop()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
