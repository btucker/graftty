import Testing
import Foundation
@testable import GrafttyKit

/// ATTN-2.11: a client that sends an unbounded stream of data must not
/// grow the per-connection buffer without limit. The SO_RCVTIMEO gate
/// only fires when data STOPS flowing — a writer that keeps the pipe
/// continuously full never triggers it, so the historical read loop
/// would accumulate every byte the attacker sent until OOM.
@Suite("""
SocketServer — per-client buffer cap

@spec ATTN-2.11: Each accepted client connection's read loop shall cap total accumulated bytes at `SocketServer.maxPerClientBytes` (1 MB in production) before giving up and closing the fd. Without this, a local writer that keeps the pipe continuously full (`cat /dev/urandom | nc -U graftty.sock`) never trips `SO_RCVTIMEO` (which fires only when data STOPS flowing) — the historical unbounded read loop would grow the per-connection buffer until process memory was exhausted. 1 MB is 1000× the ≤~1 KB typical JSON notify/pane message size, so well-behaved clients never hit it. Tests can shrink the cap to bound per-test runtime.
""", .serialized)
struct SocketServerBufferCapTests {
    @Test func clientFloodingOverCapStopsReading() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let reader = descriptors[0]
        let writer = descriptors[1]
        defer {
            close(reader)
            close(writer)
        }

        let cap = 4 * 1024
        let payload = Data(repeating: 0x61, count: cap + 1)
        async let captured: Data = withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: SocketServer.readClientPayload(
                        fd: reader,
                        cap: cap
                    )
                )
            }
        }
        try payload.withUnsafeBytes { bytes in
            let base = try #require(
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            )
            try SocketIO.writeAll(fd: writer, bytes: base, count: bytes.count)
        }

        let buffer = await captured
        #expect(buffer.count == cap)
        #expect(buffer == payload.prefix(cap))
    }
}
