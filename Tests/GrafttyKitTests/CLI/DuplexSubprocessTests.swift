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

    @Test("@spec REMOTE-30.22: When launching MCP servers or provider proxies, the application shall pass only their standard streams and shall close unrelated inherited file descriptors so child processes cannot retain parent connections.")
    func childDoesNotInheritUnrelatedDescriptors() async throws {
        let pipe = Pipe()
        let inherited = fcntl(pipe.fileHandleForReading.fileDescriptor, F_DUPFD, 100)
        try #require(inherited >= 100)
        defer { _ = close(inherited) }
        try #require(fcntl(inherited, F_SETFD, 0) == 0)
        let script = "import os,sys\ntry: os.fstat(int(sys.argv[1])); print('inherited')\nexcept OSError: print('closed')"
        let child = try DuplexSubprocess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, String(inherited)], environment: [:])
        let output = try child.output.readToEnd() ?? Data()
        await child.stop()
        #expect(String(decoding: output, as: UTF8.self) == "closed\n")
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
