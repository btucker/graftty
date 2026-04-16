import Testing
import Foundation
@testable import EspalierKit

@Suite("Socket Integration Tests")
struct SocketIntegrationTests {
    @Test func serverReceivesMessage() async throws {
        // Use /tmp (short path) to keep the socket path under the 104-byte
        // sockaddr_un.sun_path limit. See startReplacesStaleSocketFile for
        // the gory details.
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("espalier-sock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let received = MutableBox<NotificationMessage?>(nil)

        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { msg in received.value = msg }
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        // Connect as client
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connectResult == 0)
        let msg = #"{"type":"notify","path":"/tmp/wt","text":"test"}"# + "\n"
        msg.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
        close(fd)

        try await Task.sleep(for: .milliseconds(200))
        server.stop()

        #expect(received.value != nil)
        if case .notify(let path, let text, _) = received.value {
            #expect(path == "/tmp/wt")
            #expect(text == "test")
        } else { Issue.record("Expected .notify message") }
    }

    /// After a crash (kill -9, power loss, etc.), the Unix domain socket
    /// file is left on disk. The next `SocketServer.start()` call must
    /// replace it rather than fail with EADDRINUSE. Without this, the
    /// user would have to manually delete `espalier.sock` after every
    /// hard crash — the kind of papercut Andy rage-quits at.
    ///
    /// This simulates the scenario by seeding a stale regular file at the
    /// socket path (representing the orphan from the previous process)
    /// and asserting that `start()` cleanly replaces it and accepts
    /// incoming messages.
    @Test func startReplacesStaleSocketFile() async throws {
        // Use /tmp directly rather than FileManager.default.temporaryDirectory.
        // The latter is under `/var/folders/sl/<long>/T/`, which combined with
        // a UUID and filename blows past sockaddr_un.sun_path's 104-byte limit
        // and triggers SocketServerError.socketPathTooLong. /tmp is short.
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("espalier-stale-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        #expect(socketPath.utf8.count <= SocketServer.maxPathBytes)

        // Seed a stale file at the socket path to simulate a crashed
        // previous instance. Make it slightly unusual (non-empty,
        // non-socket) so any accidental "only delete if it looks like
        // a socket" logic would also get caught.
        FileManager.default.createFile(
            atPath: socketPath,
            contents: Data("stale contents".utf8),
            attributes: nil
        )
        #expect(FileManager.default.fileExists(atPath: socketPath))
        let preInode = (try? FileManager.default.attributesOfItem(atPath: socketPath)[.systemFileNumber] as? UInt64) ?? 0
        #expect(preInode != 0)

        let received = MutableBox<NotificationMessage?>(nil)
        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { msg in received.value = msg }

        // This must not throw, even though the stale file exists.
        try server.start()
        defer { server.stop() }

        try await Task.sleep(for: .milliseconds(100))

        // Verify the file at socketPath is now a socket (post-unlink,
        // post-bind) and is a different inode than the stale one.
        let postAttrs = try? FileManager.default.attributesOfItem(atPath: socketPath)
        #expect(postAttrs?[.type] as? FileAttributeType == .typeSocket)
        let postInode = (postAttrs?[.systemFileNumber] as? UInt64) ?? 0
        #expect(postInode != 0)
        #expect(postInode != preInode)

        // End-to-end: a client can connect and the server receives the
        // message. This catches regressions where start() appears to
        // succeed but the server isn't actually listening.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connectResult == 0)
        let msg = #"{"type":"notify","path":"/tmp/wt","text":"after-crash"}"# + "\n"
        msg.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
        close(fd)

        try await Task.sleep(for: .milliseconds(200))

        #expect(received.value != nil)
        if case .notify(_, let text, _) = received.value {
            #expect(text == "after-crash")
        } else { Issue.record("Expected .notify message after stale-file recovery") }
    }

    /// macOS's `sockaddr_un.sun_path` is 104 bytes. If we let a too-long path
    /// through unchecked, `bind()` happily truncates it and creates a socket
    /// at the wrong location — the server then "works" but listens on a
    /// silently-different path than the client expects. `start()` must
    /// detect this and throw before touching the socket APIs.
    ///
    /// This caught a real bug during dogfooding: the original
    /// `serverReceivesMessage` test only worked because both server and
    /// client used the same truncation, so they coincidentally connected
    /// through the truncated path.
    /// The CLI (in `SocketClient.send`) uses this same constant to reject
    /// too-long paths before attempting connect(). If the value ever drifts,
    /// server and client would disagree about which paths are valid. Pin it
    /// to macOS's documented `sockaddr_un.sun_path` size minus 1 for the
    /// null terminator.
    @Test func maxPathBytesMatchesSunPathSizeMinusNull() {
        #expect(SocketServer.maxPathBytes == 103)
    }

    @Test func startRejectsPathLongerThanSunPath() {
        // 104 'a's — exceeds the 103-byte limit (null terminator steals one
        // byte from the 104-byte sun_path buffer).
        let overLongPath = "/tmp/" + String(repeating: "a", count: 100)
        #expect(overLongPath.utf8.count > SocketServer.maxPathBytes)

        let server = SocketServer(socketPath: overLongPath)
        #expect(throws: SocketServerError.self) {
            try server.start()
        }
    }
}

final class MutableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
