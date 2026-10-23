import Foundation
import Testing
@testable import GrafttyKit

@Suite("Subprocess pipe capture")
struct SubprocessPipeEOFTests {
    @Test("@spec CLI-1.4: When a piped subprocess exits, the application shall return its captured output without waiting for a pipe's end-of-file, even when a background child still holds that pipe open.")
    func exitDoesNotWaitForAHeldPipe() async throws {
        // `sleep` inherits stdout and stderr, so neither pipe reaches EOF
        // until it exits, long after `sh` has. Before CLI-1.4 the call waited
        // out a five-second EOF timeout (and, on macOS, lost the output).
        let started = ContinuousClock.now
        let output = try await Subprocess.run(SubprocessLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2; sleep 30 &"],
            timeoutLabel: "sh"
        ))
        let elapsed = ContinuousClock.now - started

        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: output.stderr, as: UTF8.self) == "err\n")
        #expect(elapsed < .milliseconds(4500), "returned after \(elapsed)")
    }

    @Test("Output written just before exit is captured in full")
    func lastWritesBeforeExitAreKept() async throws {
        for _ in 0..<20 {
            let output = try await Subprocess.run(SubprocessLaunch(
                executable: "/bin/sh",
                arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' a; printf tail; printf oops >&2"],
                timeoutLabel: "sh"
            ))
            #expect(output.stdout.count == 200_004)
            #expect(output.stdout.suffix(4) == Data("tail".utf8))
            #expect(output.stderr == Data("oops".utf8))
        }
    }
}
