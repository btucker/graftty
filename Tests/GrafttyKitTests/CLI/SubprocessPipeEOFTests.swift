import Foundation
import Testing
@testable import GrafttyKit

@Suite("Subprocess pipe capture")
struct SubprocessPipeEOFTests {
    /// Before CLI-1.4 the termination handler blocked until both readability
    /// callbacks reported EOF. On Linux those callbacks can queue behind it,
    /// so commands randomly waited out the five-second EOF timeout (twenty of
    /// these took 25 s in `swift:6.2.3-noble`).
    @Test("@spec CLI-1.4: When a piped subprocess exits, the application shall return all of its output without waiting out an end-of-file timeout.")
    func exitReturnsOutputWithoutAnEOFWait() async throws {
        for _ in 0..<20 {
            let started = ContinuousClock.now
            let output = try await Subprocess.run(SubprocessLaunch(
                executable: "/bin/sh",
                arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' a; printf tail; printf oops >&2"],
                timeoutLabel: "sh"
            ))
            let elapsed = ContinuousClock.now - started
            #expect(output.stdout.count == 200_004)
            #expect(output.stdout.suffix(4) == Data("tail".utf8))
            #expect(output.stderr == Data("oops".utf8))
            // A fast command; the EOF timeout alone took five seconds.
            #expect(elapsed < .milliseconds(4500), "took \(elapsed)")
        }
    }

    #if canImport(Darwin)
    /// A background child that inherits the pipes keeps them open after the
    /// command exits. The callback used to block in `read(upToCount:)` until
    /// that child exited, so the command waited out the EOF timeout and came
    /// back with no output. On Linux, swift-corelibs-foundation reports
    /// termination only once every process holding the socket it creates at
    /// launch has closed it, so the command still waits for such a child.
    @Test("A background child holding the pipes neither delays nor loses the output")
    func heldPipeDoesNotDelayOrLoseOutput() async throws {
        let started = ContinuousClock.now
        let output = try await Subprocess.run(SubprocessLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2; sleep 8 &"],
            timeoutLabel: "sh"
        ))
        let elapsed = ContinuousClock.now - started

        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: output.stderr, as: UTF8.self) == "err\n")
        #expect(elapsed < .milliseconds(4500), "returned after \(elapsed)")
    }
    #endif
}
