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

    private static func makeSocketPath() throws -> (dir: URL, path: String) {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-sock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("s").path)
    }

    private static func connect(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strlcpy(dest, ptr, 104)
                }
            }
        }
        let r = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(r == 0, "connect failed: errno=\(errno)")
        // Prevent SIGPIPE when the server stops reading — the test
        // deliberately overflows the cap, and the default Darwin
        // behaviour kills the whole test process otherwise.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    @Test func clientFloodingOverCapStopsReading() async throws {
        let (dir, socketPath) = try Self.makeSocketPath()
        defer { try? FileManager.default.removeItem(at: dir) }

        let received = MutableBox<[String]>([])

        let server = SocketServer(socketPath: socketPath)
        // Shrink the cap to 4 KB so the test finishes in milliseconds.
        server.maxPerClientBytes = 4 * 1024
        server.onMessage = { msg in
            if case .notify(_, let text, _, _) = msg {
                received.value.append(text)
            }
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(50))

        let fd = Self.connect(to: socketPath)
        defer { close(fd) }

        let lines = (0..<500).map { index in
            #"{"type":"notify","path":"/tmp/wt","text":"\#(index)"}"# + "\n"
        }
        let payload = lines.joined()
        let cappedPayload = Data(payload.utf8.prefix(server.maxPerClientBytes))
        let expectedTexts = String(decoding: cappedPayload, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let message = try? JSONDecoder().decode(
                    NotificationMessage.self,
                    from: Data(line.utf8)
                ), case .notify(_, let text, _, _) = message else {
                    return nil
                }
                return text
            }

        // The server may close while this deliberately oversized write is in
        // progress. SO_NOSIGPIPE above turns that expected condition into a
        // normal EPIPE result.
        try? SocketIO.writeAll(fd: fd, string: payload)
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var byte: UInt8 = 0
        #expect(Darwin.read(fd, &byte, 1) == 0)

        // Every onMessage block was queued before the worker closed its fd.
        // Queue one sentinel behind them instead of sleeping an arbitrary time.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(received.value == expectedTexts)
    }
}
