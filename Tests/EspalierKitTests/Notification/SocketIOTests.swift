import Testing
import Foundation
import Darwin
@testable import EspalierKit

@Suite("SocketIO.writeAll")
struct SocketIOTests {

    /// Helper: make a connected socketpair for send/receive testing.
    /// Returns (writer, reader) fds; both must be closed by the caller.
    private func makeSocketPair() -> (Int32, Int32)? {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        return (fds[0], fds[1])
    }

    @Test func writesShortPayloadInOnePass() throws {
        guard let (writer, reader) = makeSocketPair() else {
            Issue.record("socketpair failed")
            return
        }
        defer { close(writer); close(reader) }

        let message = #"{"type":"ok"}"# + "\n"
        try SocketIO.writeAll(fd: writer, string: message)

        var buf = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(reader, &buf, buf.count)
        #expect(n > 0)
        let received = String(bytes: buf[0..<Int(n)], encoding: .utf8)
        #expect(received == message)
    }

    @Test func writesLargePayloadAcrossMultiplePasses() throws {
        // Shrink SO_SNDBUF on the writer side so the kernel can't
        // absorb the whole payload in a single `write`. This is the
        // exact scenario that `WebServer` already exercises via
        // `testingChildSndBuf` for HTTP responses — here we prove
        // writeAll loops correctly for the same bug class.
        guard let (writer, reader) = makeSocketPair() else {
            Issue.record("socketpair failed")
            return
        }
        defer { close(writer); close(reader) }
        var sndbuf: Int32 = 2048
        setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &sndbuf,
                   socklen_t(MemoryLayout<Int32>.size))

        // Payload deliberately larger than the 2 KB buffer so a naive
        // one-shot write would truncate.
        let large = String(repeating: "x", count: 16_000)

        // Drain on a background thread so the writer doesn't block
        // indefinitely on a full kernel buffer.
        let received = MutableBox<Data>(Data())
        let drainer = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var total = Data()
            while true {
                let n = Darwin.read(reader, &buf, buf.count)
                if n <= 0 { break }
                total.append(contentsOf: buf[0..<Int(n)])
                if total.count >= 16_000 { break }
            }
            received.value = total
        }
        drainer.start()

        try SocketIO.writeAll(fd: writer, string: large)

        // Close the write side so the reader's read returns 0 (EOF)
        // if it hasn't hit the length threshold yet.
        shutdown(writer, Int32(SHUT_WR))
        while drainer.isExecuting { Thread.sleep(forTimeInterval: 0.01) }

        #expect(received.value.count == 16_000)
        // All bytes should be 'x'.
        #expect(received.value.allSatisfy { $0 == 0x78 })
    }

    @Test func throwsOnInvalidFD() {
        #expect(throws: SocketIO.WriteError.self) {
            try SocketIO.writeAll(fd: -1, string: "hello")
        }
    }

    @Test func emptyPayloadIsNoOp() throws {
        guard let (writer, reader) = makeSocketPair() else {
            Issue.record("socketpair failed")
            return
        }
        defer { close(writer); close(reader) }

        // Empty buffer → zero iterations, no throw, no bytes sent.
        try SocketIO.writeAll(fd: writer, string: "")
    }
}
