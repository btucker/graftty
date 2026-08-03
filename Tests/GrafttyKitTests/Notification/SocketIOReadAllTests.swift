import Testing
import Foundation
@testable import GrafttyKit

/// `ATTN-3.6`: last-resort cap on the CLI's response-read path.
/// Tests use `socketpair`, write a
/// synchronous payload that fits in the kernel send buffer, then
/// half-close the write side — no threads, no deadlock on kernel
/// backpressure.
@Suite("""
SocketIO.readAll — per-peer byte cap

@spec ATTN-3.6: The CLI's response-read path shall cap total accumulated bytes at 16 MiB and report when the peer sent more than that limit, so an oversized response is not misreported as malformed JSON. This response cap is independent of the server's incoming-request cap; normal bulk commands shall paginate below it.
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
        try block.withUnsafeBufferPointer { p in
            try SocketIO.writeAll(fd: a, bytes: p.baseAddress!, count: p.count)
        }
        _ = shutdown(a, SHUT_WR)

        let buffer = SocketIO.readAll(fd: b, cap: cap)
        #expect(buffer.count == cap, "readAll must cap at \(cap); got \(buffer.count)")
    }

    @Test func readCappedReportsWhenPeerExceedsLimit() throws {
        let (a, b) = Self.makePair()
        defer { close(a); close(b) }

        let payloadSize = 8 * 1024
        let cap = 4 * 1024
        var buf: Int32 = Int32(payloadSize * 2)
        _ = setsockopt(a, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(b, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))

        let block = [UInt8](repeating: 0x43, count: payloadSize)
        try block.withUnsafeBufferPointer { p in
            try SocketIO.writeAll(fd: a, bytes: p.baseAddress!, count: p.count)
        }
        _ = shutdown(a, SHUT_WR)

        let result = SocketIO.readCapped(fd: b, cap: cap)
        #expect(result.data.count == cap)
        #expect(result.exceededCap)
    }

    @Test func readCappedDoesNotFlagAnExactLimitResponse() throws {
        let (a, b) = Self.makePair()
        defer { close(a); close(b) }

        let cap = 1024
        let block = [UInt8](repeating: 0x44, count: cap)
        try block.withUnsafeBufferPointer { p in
            try SocketIO.writeAll(fd: a, bytes: p.baseAddress!, count: p.count)
        }
        _ = shutdown(a, SHUT_WR)

        let result = SocketIO.readCapped(fd: b, cap: cap)
        #expect(result.data.count == cap)
        #expect(!result.exceededCap)
    }

    @Test func readAllReturnsEarlyOnEOF() throws {
        let (a, b) = Self.makePair()
        defer { close(a); close(b) }

        let payload = [UInt8](repeating: 0x42, count: 100)
        try payload.withUnsafeBufferPointer { buf in
            try SocketIO.writeAll(fd: a, bytes: buf.baseAddress!, count: buf.count)
        }
        _ = shutdown(a, SHUT_WR)

        let buffer = SocketIO.readAll(fd: b, cap: 10 * 1024)
        #expect(buffer.count == 100, "readAll should stop at EOF, not wait for cap; got \(buffer.count)")
    }

    @Test func readAllReturnsEmptyWhenPeerClosesImmediately() {
        let (a, b) = Self.makePair()
        defer { close(a); close(b) }
        _ = shutdown(a, SHUT_WR)  // writer closes its half without sending anything

        let buffer = SocketIO.readAll(fd: b, cap: 1024)
        #expect(buffer.isEmpty, "readAll on EOF-only peer returns empty; got \(buffer.count) bytes")
    }
}
