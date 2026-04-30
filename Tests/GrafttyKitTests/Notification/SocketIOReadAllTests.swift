import Testing
import Foundation
@testable import GrafttyKit

/// `ATTN-3.6`: mirror of the server-side `ATTN-2.11` cap on the
/// CLI's response-read path. Tests use `socketpair`, write a
/// synchronous payload that fits in the kernel send buffer, then
/// close the write side — no threads, no deadlock on kernel
/// backpressure.
@Suite("""
SocketIO.readAll — per-peer byte cap

@spec ATTN-3.6: The CLI's response-read path shall cap total accumulated bytes at 1 MB via `SocketIO.readAll(fd:cap:)`. Mirrors the server-side `ATTN-2.11`: `SO_RCVTIMEO` only fires on idle pipes, so a misbehaving or compromised server that keeps the pipe continuously full would otherwise grow the CLI's per-response buffer without bound. 1 MB is 1000× the typical ≤1 KB response size; a legit server never hits it.
""")
struct SocketIOReadAllTests {

    private static func makePair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let r = fds.withUnsafeMutableBufferPointer { buf in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        precondition(r == 0, "socketpair failed: errno=\(errno)")
        return (fds[0], fds[1])
    }

    @Test func readAllStopsAtCap() throws {
        let (a, b) = Self.makePair()
        defer { close(a); close(b) }

        // Expand the kernel send buffer so a synchronous write of
        // `payloadSize` fits without blocking the test. Default
        // SO_SNDBUF on a macOS Unix socketpair is ~8 KB.
        let payloadSize = 8 * 1024
        let cap = 4 * 1024
        var buf: Int32 = Int32(payloadSize * 2)
        _ = setsockopt(a, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(b, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))

        let block = [UInt8](repeating: 0x41, count: payloadSize)
        let written = block.withUnsafeBufferPointer { p in
            Darwin.write(a, p.baseAddress, p.count)
        }
        #expect(written == payloadSize, "socketpair write should succeed; got \(written)")
        close(a)

        let buffer = SocketIO.readAll(fd: b, cap: cap)
        #expect(buffer.count == cap, "readAll must cap at \(cap); got \(buffer.count)")
    }

    @Test func readAllReturnsEarlyOnEOF() {
        let (a, b) = Self.makePair()
        defer { close(a); close(b) }

        let payload = [UInt8](repeating: 0x42, count: 100)
        _ = payload.withUnsafeBufferPointer { buf in
            Darwin.write(a, buf.baseAddress, buf.count)
        }
        close(a)

        let buffer = SocketIO.readAll(fd: b, cap: 10 * 1024)
        #expect(buffer.count == 100, "readAll should stop at EOF, not wait for cap; got \(buffer.count)")
    }

    @Test func readAllReturnsEmptyWhenPeerClosesImmediately() {
        let (a, b) = Self.makePair()
        defer { close(a); close(b) }
        close(a)  // writer closes without sending anything

        let buffer = SocketIO.readAll(fd: b, cap: 1024)
        #expect(buffer.isEmpty, "readAll on EOF-only peer returns empty; got \(buffer.count) bytes")
    }
}
