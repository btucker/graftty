import Testing
import Foundation
@testable import GrafttyKit

/// ATTN-2.11: a client that sends an unbounded stream of data must not
/// grow the per-connection buffer without limit. The SO_RCVTIMEO gate
/// only fires when data STOPS flowing — a writer that keeps the pipe
/// continuously full never triggers it, so the historical read loop
/// would accumulate every byte the attacker sent until OOM.
@Suite("SocketServer — per-client buffer cap", .serialized)
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
            if case .notify(_, let text, _) = msg {
                received.value.append(text)
            }
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(50))

        let fd = Self.connect(to: socketPath)
        defer { close(fd) }

        // Each message: 44 bytes. With cap at 4 KB, the server reads at
        // most ~93 messages worth before stopping. We'll send 500
        // messages (~22 KB, well past the cap) and assert the server
        // processed fewer than all of them — pin that the cap kicked
        // in.
        for i in 0..<500 {
            let line = #"{"type":"notify","path":"/tmp/wt","text":"\#(i)"}"# + "\n"
            line.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
        }
        close(fd)

        try await Task.sleep(for: .milliseconds(400))

        #expect(
            received.value.count < 500,
            "server must stop reading at the per-client cap; got \(received.value.count) messages"
        )
        #expect(
            !received.value.isEmpty,
            "messages that fit within the cap should still be processed"
        )
    }
}
