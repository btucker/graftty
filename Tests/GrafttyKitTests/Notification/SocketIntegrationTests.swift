import Testing
import Foundation
@testable import GrafttyKit

// `.serialized` because `slowOnRequestClosesClientFDAtTimeout` and
// `silentClientDoesNotBlockOtherClients` both deliberately block the
// main dispatch queue for a handful of seconds to simulate the hang
// conditions they cover. Letting them run in parallel with peer
// tests in this suite causes those peers' `DispatchQueue.main.async`
// callbacks to stall past their `try await Task.sleep` windows and
// fail spuriously.
@Suite("Socket Integration Tests", .serialized)
struct SocketIntegrationTests {
    @Test func serverReceivesMessage() async throws {
        // Use /tmp (short path) to keep the socket path under the 104-byte
        // sockaddr_un.sun_path limit. See startReplacesStaleSocketFile for
        // the gory details.
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-sock-\(UUID().uuidString.prefix(8))")
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
    /// user would have to manually delete `graftty.sock` after every
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
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-stale-\(UUID().uuidString.prefix(8))")
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

    /// ATTN-2.7: `start()` records its failure in `lastStartError` so
    /// callers (notably `GrafttyApp.startup` which historically used
    /// `try?` and discarded the error) have a diagnostic trail the UI
    /// or log path can read back, instead of silently running without
    /// a notify surface.
    @Test("""
    @spec ATTN-2.7: When `SocketServer.start()` fails during application startup, the application shall (a) log the error via `NSLog` (surfacing it in Console.app), (b) retain the error in `SocketServer.lastStartError` for in-process introspection, and (c) present a one-time `NotifySocketBanner` alert describing what broke and suggesting recovery steps (quit+relaunch, clear `GRAFTTY_SOCK`). The banner mirrors the `ZmxFallbackBanner` pattern from `ZMX-5.2`. The app shell historically wrapped `start()` in `try?`, producing a running Graftty with a dead control socket and no diagnostic trail — ATTN-3.4 recovers this case at the CLI side, ATTN-2.7 surfaces the root cause at the app side upfront rather than waiting for the user to trip over the CLI.
    """)
    func lastStartErrorCapturesFailure() {
        let overLongPath = "/tmp/" + String(repeating: "a", count: 100)
        let server = SocketServer(socketPath: overLongPath)
        #expect(server.lastStartError == nil, "fresh server should have no error")

        _ = try? server.start()
        guard case .socketPathTooLong = server.lastStartError else {
            Issue.record("expected .socketPathTooLong, got \(String(describing: server.lastStartError))")
            return
        }
    }

    @Test func lastStartErrorClearsOnSuccessfulRestart() throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-err-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let goodPath = dir.appendingPathComponent("s").path

        // First start: fail with overlong path.
        let bad = "/tmp/" + String(repeating: "a", count: 100)
        let server = SocketServer(socketPath: bad)
        _ = try? server.start()
        #expect(server.lastStartError != nil)

        // Re-issue start() on a fresh instance with a good path; the
        // new server's lastStartError stays nil because start() cleared
        // it on success.
        let good = SocketServer(socketPath: goodPath)
        try good.start()
        defer { good.stop() }
        #expect(good.lastStartError == nil)
    }

    @Test func serverWritesResponseWhenOnRequestSet() async throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-resp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let server = SocketServer(socketPath: socketPath)
        server.onRequest = { msg in
            guard case .listPanes = msg else { return .error("unexpected") }
            return .paneList([
                PaneInfo(id: 1, title: "zsh", focused: true),
                PaneInfo(id: 2, title: nil, focused: false),
            ])
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))

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

        let req = #"{"type":"list_panes","path":"/tmp/wt"}"# + "\n"
        req.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }

        // Half-close the write side so the server's read-until-EOF terminates
        // and proceeds to send the response. Without SHUT_WR, the server would
        // block waiting for more bytes.
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(fd, &buffer, 4096)
        close(fd)
        #expect(bytesRead > 0)

        let data = Data(buffer[0..<bytesRead])
        let line = String(data: data, encoding: .utf8)!
            .components(separatedBy: "\n")
            .first(where: { !$0.isEmpty })!
        let response = try JSONDecoder().decode(ResponseMessage.self, from: line.data(using: .utf8)!)
        guard case .paneList(let panes) = response else {
            Issue.record("Expected .paneList")
            return
        }
        #expect(panes.count == 2)
        #expect(panes[0].title == "zsh")
        #expect(panes[0].focused == true)
    }

    @Test func serverOmitsResponseWhenOnRequestUnset() async throws {
        // Fire-and-forget path must still work — notify/clear don't expect replies.
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-fnf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let received = MutableBox<NotificationMessage?>(nil)
        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { msg in received.value = msg }
        // Intentionally no onRequest.
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let msg = #"{"type":"notify","path":"/tmp/wt","text":"hi"}"# + "\n"
        msg.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))

        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = Darwin.read(fd, &buffer, 1024)
        close(fd)
        // Server closes without writing anything; read returns 0 (EOF).
        #expect(bytesRead == 0)

        try await Task.sleep(for: .milliseconds(100))
        #expect(received.value != nil)
    }

    /// `onRequest` runs on the main queue; if the main queue stalls
    /// (modal dialog, long synchronous work, a main-actor reentrancy
    /// bug), `semaphore.wait()` on the socket queue blocks forever and
    /// pins every subsequent request behind it — same serial-queue
    /// pile-up shape as `silentClientDoesNotBlockOtherClients` but at
    /// the request/response path.
    ///
    /// The server shall cap its wait with a bounded timeout and, on
    /// expiry, close the client fd without a response. The CLI's
    /// client-side `ATTN-3.3` 2s timeout then surfaces that as
    /// `socketTimeout` to the user. Observable: client's `read()` sees
    /// EOF within the server's timeout window + small margin, not after
    /// onRequest's full duration.
    @Test("""
    @spec ATTN-2.10: When a request-style socket message (`list_panes`, `add_pane`, `close_pane`) hands its handler to the main queue via `DispatchQueue.main.async`, the server shall wait at most `SocketServer.onRequestTimeout` (5 seconds in production) for the handler to return. If the handler has not completed within that window — main queue stalled by a modal dialog, heavy synchronous work, or a main-actor reentrancy bug — the server shall close the client fd without writing a response rather than pin its serial worker on `semaphore.wait()` indefinitely. The CLI's 2s client-side timeout (`ATTN-3.3`) then surfaces the event as a clean `socketTimeout`. The main-queue closure may still complete and write into the retained response box after the worker has returned; its `signal()` lands on a no-longer-awaited semaphore harmlessly.
    """)
    func slowOnRequestClosesClientFDAtTimeout() async throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-slow-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path

        let server = SocketServer(socketPath: socketPath)
        server.onRequestTimeout = .seconds(1)
        // onRequest blocks main on a gate the test releases at the
        // end. This emulates a stalled main queue (modal / heavy work)
        // without Thread.sleep-ing for the full duration — which
        // would pin main past the end of this test and interfere with
        // peer tests in the suite that also dispatch to main.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        server.onRequest = { _ in
            _ = gate.wait(timeout: .now() + 10)
            return .ok
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Client-side read timeout of 3s — if server doesn't close
        // within that, we'd see EAGAIN (-1) rather than EOF (0).
        var rcvTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))

        let msg = #"{"type":"notify","path":"/tmp/wt","text":"slow"}"# + "\n"
        msg.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
        // Half-close write side so the server's read loop exits
        // immediately (EOF) rather than waiting out its 2s
        // SO_RCVTIMEO (cycle 131 ATTN-2.9). Keep read side open so
        // we can observe EOF from server-initiated close.
        shutdown(fd, Int32(SHUT_WR))

        let start = Date()
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.read(fd, &buf, 1024)
        let elapsed = Date().timeIntervalSince(start)

        // EOF = 0 means server closed the fd. Pre-fix: wait the full
        // 10s for onRequest to finish (or client-side 3s timeout
        // fires first as EAGAIN). Post-fix: server times out at 1s
        // and closes fd, so n == 0 within ~1.5s.
        #expect(n == 0, "Server must close fd at timeout, not wait for onRequest")
        #expect(elapsed < 2.0, "Server must honor its 1s timeout, not wait for onRequest's 10s (elapsed: \(elapsed)s)")
    }

    /// A silent client that connects but never writes or closes must not
    /// block subsequent clients from being handled. Previously
    /// `SocketServer.handleClient` did `read()` in a loop with no
    /// `SO_RCVTIMEO`, so a hung peer pinned the server's serial dispatch
    /// queue indefinitely — a trivial local DoS: any process doing
    /// `nc -U ~/…/graftty.sock` would freeze every `graftty notify`
    /// until the peer closed. Exactly Andy's "furious when any tool
    /// kills a long-running shell unexpectedly" pain point in the
    /// server-accept-queue dimension.
    @Test("""
    @spec ATTN-2.9: Each accepted client connection shall have `SO_RCVTIMEO` set to 2 seconds before the server enters its read loop. Without this, a silent peer (a `nc -U` that connects but never writes, a crashed CLI client whose kernel-level connection lingers, etc.) pins the server's serial dispatch queue on a blocking `read(2)` indefinitely — and since `acceptConnection` shares that queue, every subsequent `graftty notify` hangs for the duration. 2 seconds mirrors the CLI's client-side timeout (`ATTN-3.3`); JSON notify/pane messages are ≤~1 KB over a local socket, so any well-behaved client finishes in milliseconds.
    """)
    func silentClientDoesNotBlockOtherClients() async throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-hang-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let received = MutableBox<NotificationMessage?>(nil)

        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { msg in received.value = msg }
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        func connectClient() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            socketPath.withCString { ptr in
                withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                    pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
                }
            }
            let rc = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(rc == 0)
            return fd
        }

        // Connection #1: silent — connect but neither write nor close
        // until test teardown. Pre-fix, this pins the serial queue on
        // `handleClient`'s blocking `read()` forever.
        let silentFD = connectClient()
        defer { close(silentFD) }

        // Give the server a beat to accept + begin handling #1.
        try await Task.sleep(for: .milliseconds(100))

        // Connection #2: valid — write one message and close.
        let activeFD = connectClient()
        let msg = #"{"type":"notify","path":"/tmp/wt","text":"test"}"# + "\n"
        msg.withCString { ptr in _ = Darwin.write(activeFD, ptr, strlen(ptr)) }
        close(activeFD)

        // Wait comfortably longer than the 2s server-side read timeout
        // so handler #1 finishes and the serial queue drains to #2.
        try await Task.sleep(for: .milliseconds(2800))
        server.stop()

        #expect(received.value != nil,
                "Silent client blocked the serial dispatch queue; message from the valid client was never processed.")
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
