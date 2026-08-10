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
        let (messages, messageContinuation) = AsyncStream.makeStream(of: NotificationMessage.self)
        defer { messageContinuation.finish() }

        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { messageContinuation.yield($0) }
        try server.start()
        defer { server.stop() }

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

        let received = try await expectMessage(from: messages)
        if case .notify(let path, let text, _, _) = received {
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

        let (messages, messageContinuation) = AsyncStream.makeStream(of: NotificationMessage.self)
        defer { messageContinuation.finish() }
        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { messageContinuation.yield($0) }

        // This must not throw, even though the stale file exists.
        try server.start()
        defer { server.stop() }

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

        let received = try await expectMessage(from: messages)
        if case .notify(_, let text, _, _) = received {
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

    @Test("""
    @spec ATTN-2.8: The application's Unix-domain socket server shall call `listen(2)` with a backlog of 64, not the historical default of 5. A user scripting parallel `graftty notify` invocations (e.g. from a hook that fans out across a monorepo) can easily exceed 5 pending connections, and the extra backlog entries cost negligible kernel resources while preventing spurious `ECONNREFUSED` for the later clients.
    """)
    func listenBacklogIsSixtyFour() {
        #expect(SocketServer.listenBacklog == 64)
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

    @Test("Async request handler may suspend without blocking the main actor")
    func serverWritesResponseFromAsyncRequestHandler() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-async-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let server = SocketServer(socketPath: socketPath)
        server.onAsyncRequest = { message in
            guard case .listPanes = message else {
                return .error("unexpected")
            }
            try? await Task.sleep(for: .milliseconds(25))
            return .paneList([
                PaneInfo(id: 1, title: "zmx", focused: true),
            ])
        }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let response = try Self.sendRequest(
            socketPath: socketPath,
            json: #"{"type":"list_panes","path":"/tmp/wt"}"#
        )
        #expect(
            response == .paneList([
                PaneInfo(id: 1, title: "zmx", focused: true),
            ])
        )
    }

    @Test("""
    @spec ATTN-2.12: While one control-socket client request handler is suspended, the application shall accept and handle independent client connections concurrently so a fast request is not delayed behind the slow request.
    """)
    func slowRequestDoesNotDelayIndependentFastRequest() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-hol-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let (slowStarts, slowStartContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { slowStartContinuation.finish() }
        let slowGate = AsyncGate()

        let server = SocketServer(socketPath: socketPath)
        server.onAsyncRequest = { message in
            switch message {
            case .listPanes:
                slowStartContinuation.yield(())
                await slowGate.wait()
                return .paneList([])
            case .teamMessage:
                return .ok
            default:
                return .error("unexpected")
            }
        }
        try server.start()
        defer { server.stop() }

        let slowRequest = Task.detached {
            try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"list_panes","path":"/tmp/slow"}"#
            )
        }

        try await expectSignal(from: slowStarts)

        let (fastFinishes, fastFinishContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { fastFinishContinuation.finish() }
        let fastRequest = Task.detached {
            let result: Result<ResponseMessage, Error> = Result {
                try Self.sendRequest(
                    socketPath: socketPath,
                    json: #"{"type":"team_message","caller_worktree":"/tmp/fast","recipient":"peer","text":"hello"}"#
                )
            }
            fastFinishContinuation.yield(())
            return result
        }

        do {
            // The slow handler remains explicitly gated. Completion itself,
            // rather than a sub-second performance threshold, proves the fast
            // connection did not queue behind it; the timeout is terminal
            // protection for a broken implementation or test environment.
            try await expectSignal(from: fastFinishes)
        } catch {
            await slowGate.open()
            _ = await fastRequest.value
            _ = try? await slowRequest.value
            throw error
        }
        let fastResult = await fastRequest.value
        await slowGate.open()

        #expect(try fastResult.get() == .ok)
        #expect(try await slowRequest.value == .paneList([]))
    }

    @Test("""
    @spec ATTN-2.24: While admitted control-socket request handlers are suspended, the application shall start each additional admitted client's receive and handler deadline independently of those blocked workers so a fast request cannot expire while waiting to begin processing.
    """)
    func admittedClientsStartIndependentlyOfBlockedWorkers() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-worker-saturation-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let (slowStarts, slowStartContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { slowStartContinuation.finish() }
        let slowGate = AsyncGate()
        let server = SocketServer(
            socketPath: socketPath,
            clientQueue: DispatchQueue(
                label: "com.graftty.socket-server.serial-test-client"
            )
        )
        server.onAsyncRequest = { message in
            switch message {
            case .listPanes:
                slowStartContinuation.yield(())
                await slowGate.wait()
                return .paneList([])
            case .teamMessage:
                return .ok
            default:
                return .error("unexpected")
            }
        }
        try server.start()
        defer {
            Task { await slowGate.open() }
            server.stop()
        }

        let slowRequest = Task.detached {
            try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"list_panes","path":"/tmp/slow"}"#
            )
        }
        try await expectSignal(from: slowStarts)

        let (fastFinishes, fastFinishContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { fastFinishContinuation.finish() }
        let fastRequest = Task.detached {
            let result: Result<ResponseMessage, Error> = Result {
                try Self.sendRequest(
                    socketPath: socketPath,
                    json: #"{"type":"team_message","caller_worktree":"/tmp/fast","recipient":"peer","text":"hello"}"#
                )
            }
            fastFinishContinuation.yield(())
            return result
        }

        do {
            try await expectSignal(from: fastFinishes, timeout: .seconds(1))
        } catch {
            await slowGate.open()
            _ = await fastRequest.value
            _ = try? await slowRequest.value
            throw error
        }
        let fastResult = await fastRequest.value
        await slowGate.open()

        #expect(try fastResult.get() == .ok)
        #expect(try await slowRequest.value == .paneList([]))
    }

    @Test("""
    @spec ATTN-2.13: When one client connection sends multiple request lines, the application shall write their responses in request order even when an earlier handler suspends.
    """)
    func responsesRemainOrderedWithinOneConnection() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-order-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let server = SocketServer(socketPath: socketPath)
        server.onAsyncRequest = { message in
            switch message {
            case .listPanes:
                try? await Task.sleep(for: .milliseconds(100))
                return .error("slow-first")
            case .teamMessage:
                return .ok
            default:
                return .error("unexpected")
            }
        }
        try server.start()
        defer { server.stop() }

        let responses = try Self.sendRequests(
            socketPath: socketPath,
            jsonLines: [
                #"{"type":"list_panes","path":"/tmp/slow"}"#,
                #"{"type":"team_message","caller_worktree":"/tmp/fast","recipient":"peer","text":"hello"}"#,
            ]
        )

        #expect(responses == [.error("slow-first"), .ok])
    }

    @Test("Request timeout terminates a multi-request connection")
    func timeoutDoesNotMisattributeALaterResponse() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-timeout-order-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let laterRequestsHandled = MutableBox(0)
        let server = SocketServer(socketPath: socketPath)
        server.onRequestTimeout = .milliseconds(100)
        server.onAsyncRequest = { message in
            switch message {
            case .listPanes:
                try? await Task.sleep(for: .milliseconds(500))
                return .error("too late")
            case .teamMessage:
                laterRequestsHandled.value += 1
                return .ok
            default:
                return .error("unexpected")
            }
        }
        try server.start()
        defer { server.stop() }

        let responseBytes = try Self.exchangeRequests(
            socketPath: socketPath,
            jsonLines: [
                #"{"type":"list_panes","path":"/tmp/slow"}"#,
                #"{"type":"team_message","caller_worktree":"/tmp/fast","recipient":"peer","text":"hello"}"#,
            ]
        )

        #expect(responseBytes.isEmpty)
        #expect(laterRequestsHandled.value == 0)
    }

    @Test("""
    @spec ATTN-2.14: When the control-socket server stops, the application shall stop accepting connections, interrupt every active client's socket I/O and request wait, and release its connection workers without waiting for handler timeouts.
    """)
    func stopInterruptsActiveRequestAndReleasesServer() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-stop-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let (slowStarts, slowStartContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { slowStartContinuation.finish() }

        let postStopMessages = MutableBox(0)
        var server: SocketServer? = SocketServer(socketPath: socketPath)
        server?.maxConcurrentClients = 2
        server?.onMessage = { message in
            if case .notify(_, let text, _, _) = message,
               text == "buffered" {
                postStopMessages.value += 1
            }
        }
        server?.onAsyncRequest = { message in
            if case .listPanes = message {
                slowStartContinuation.yield(())
                try? await Task.sleep(for: .seconds(2))
            }
            return .ok
        }
        try server?.start()

        let request = Task.detached {
            try? Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"list_panes","path":"/tmp/slow"}"#
            )
        }
        try await expectSignal(from: slowStarts)

        let silentFD = try Self.connectSocket(to: socketPath)
        defer { close(silentFD) }
        try SocketIO.writeAll(
            fd: silentFD,
            string: #"{"type":"notify","path":"/tmp/wt","text":"buffered"}"# + "\n"
        )

        // Prove the silent socket reached the server's active-client table:
        // with the slow request occupying the other configured slot, a probe
        // must be rejected. Retrying avoids assuming a fixed accept latency.
        var silentClientWasAdmitted = false
        for _ in 0..<20 {
            let probe = try? Self.exchangeRequests(
                socketPath: socketPath,
                jsonLines: [
                    #"{"type":"team_message","caller_worktree":"/tmp/probe","recipient":"peer","text":"full"}"#,
                ]
            )
            if probe.map(SocketResponseDecoder.decode)
                == .success(.serverBusy) {
                silentClientWasAdmitted = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(silentClientWasAdmitted)

        weak let weakServer = server
        server?.stop()
        server = nil

        for _ in 0..<20 where weakServer != nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(
            weakServer == nil,
            "stop must wake request waiters instead of retaining the server until timeout"
        )
        _ = await request.value
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(
            silentFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var byte: UInt8 = 0
        #expect(Darwin.read(silentFD, &byte, 1) == 0)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(postStopMessages.value == 0)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("""
    @spec ATTN-2.18: When control-socket shutdown begins during a message callback, the application shall return from `stop()` without waiting for arbitrary callback code and shall suppress request handlers still queued for the stopped generation.
    """)
    func stopDoesNotWaitForCallbackAndSuppressesQueuedHandler() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-stop-barrier-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let (callbackStarts, callbackStartContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { callbackStartContinuation.finish() }
        let releaseCallback = DispatchSemaphore(value: 0)
        let handlerCalls = MutableBox(0)
        let stopReturned = MutableBox(false)
        let (stopStarts, stopStartContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { stopStartContinuation.finish() }
        let (stopFinishes, stopFinishContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { stopFinishContinuation.finish() }

        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { _ in
            callbackStartContinuation.yield(())
            releaseCallback.wait()
        }
        server.onRequest = { _ in
            handlerCalls.value += 1
            return .ok
        }
        try server.start()
        defer {
            releaseCallback.signal()
            server.stop()
        }

        let client = Task.detached {
            try Self.exchangeRequests(
                socketPath: socketPath,
                jsonLines: [
                    #"{"type":"team_message","caller_worktree":"/tmp/old","recipient":"peer","text":"queued"}"#,
                ]
            )
        }
        try await expectSignal(from: callbackStarts)

        let stopTask = Task.detached {
            stopStartContinuation.yield(())
            server.stop()
            stopReturned.value = true
            stopFinishContinuation.yield(())
        }
        try await expectSignal(from: stopStarts)
        try await expectSignal(from: stopFinishes, timeout: .seconds(1))
        #expect(stopReturned.value, "stop waited on arbitrary callback code")

        releaseCallback.signal()
        await stopTask.value
        #expect((try await client.value).isEmpty)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(handlerCalls.value == 0)
    }

    @Test("""
    @spec ATTN-2.23: When a timed-out control-socket request's descriptor number is reused by a new client, the application shall reject the stale handler task unless its unique client lease still owns that descriptor.
    """)
    func timedOutHandlerCannotBorrowReusedDescriptor() {
        let reusedFD: Int32 = 17
        let oldLease = ClientLease(serverGeneration: 3, clientID: 41)
        let newLease = ClientLease(serverGeneration: 3, clientID: 42)
        var registry = ClientLeaseRegistry()

        registry.install(oldLease, for: reusedFD)
        #expect(registry.isOwned(fd: reusedFD, by: oldLease))

        // Deliberately reuse the same descriptor number within the same
        // server generation. This is the state the OS-dependent integration
        // test tried, but could not guarantee, to obtain from accept(2).
        registry.install(newLease, for: reusedFD)
        #expect(!registry.isOwned(fd: reusedFD, by: oldLease))
        #expect(registry.isOwned(fd: reusedFD, by: newLease))

        // A late old worker cannot remove or otherwise borrow the new lease.
        let removedNewLease = registry.remove(
            fd: reusedFD,
            ifOwnedBy: oldLease
        )
        #expect(!removedNewLease)
        #expect(registry.isOwned(fd: reusedFD, by: newLease))
    }

    @Test("""
    @spec ATTN-2.15: While 64 control-socket clients are active, the application shall reject additional request clients promptly with a structured busy response rather than misreport the immediate close as a receive timeout, and it shall admit new clients again after capacity is released.
    """)
    func concurrentClientAdmissionIsBounded() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-admit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let server = SocketServer(socketPath: socketPath)
        #expect(server.maxConcurrentClients == 64)
        server.maxConcurrentClients = 2
        let gate = AsyncGate()
        let handlersStarted = MutableBox(0)
        server.onAsyncRequest = { _ in
            handlersStarted.value += 1
            await gate.wait()
            return .ok
        }
        try server.start()
        defer { server.stop() }

        let firstRequest = Task.detached {
            try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"team_message","caller_worktree":"/tmp/one","recipient":"peer","text":"one"}"#
            )
        }
        let secondRequest = Task.detached {
            try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"team_message","caller_worktree":"/tmp/two","recipient":"peer","text":"two"}"#
            )
        }
        for _ in 0..<100 where handlersStarted.value < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            handlersStarted.value == 2,
            "both configured client slots must be admitted"
        )

        let clock = ContinuousClock()
        let rejectionStarted = clock.now
        let rejected = try? Self.exchangeRequests(
            socketPath: socketPath,
            jsonLines: [
                #"{"type":"team_message","caller_worktree":"/tmp/fast","recipient":"peer","text":"full"}"#,
            ]
        )
        let rejectionElapsed = rejectionStarted.duration(to: clock.now)
        #expect(
            rejected.map(SocketResponseDecoder.decode)
                == .success(.serverBusy)
        )
        #expect(
            rejectionElapsed < .seconds(1),
            "excess client rejection took \(rejectionElapsed)"
        )

        await gate.open()
        #expect(try await firstRequest.value == .ok)
        #expect(try await secondRequest.value == .ok)
        #expect(
            try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"team_message","caller_worktree":"/tmp/fast","recipient":"peer","text":"space"}"#
            ) == .ok
        )
    }

    @Test("""
    @spec ATTN-2.16: When a stopped control-socket server is stopped or deinitialized again after a successor has bound the same path, the application shall preserve the successor's live socket path.
    """)
    func repeatedStopDoesNotUnlinkSuccessorSocket() throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-owner-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        var first: SocketServer? = SocketServer(socketPath: socketPath)
        try first?.start()
        first?.stop()

        let successor = SocketServer(socketPath: socketPath)
        successor.onRequest = { _ in .ok }
        try successor.start()
        defer { successor.stop() }

        first?.stop()
        first = nil
        #expect(
            try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"team_message","caller_worktree":"/tmp/fast","recipient":"peer","text":"alive"}"#
            ) == .ok
        )
    }

    @Test("""
    @spec ATTN-2.17: When a stopped control-socket server restarts, the application shall keep every prior-generation connection cancelled so its buffered messages and late handler results cannot enter the new server generation.
    """)
    func restartDoesNotReviveStoppedClientWork() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("graftty-generation-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let (slowStarts, slowStartContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { slowStartContinuation.finish() }
        let teamRequestsHandled = MutableBox(0)
        let server = SocketServer(socketPath: socketPath)
        server.onAsyncRequest = { message in
            switch message {
            case .listPanes:
                slowStartContinuation.yield(())
                try? await Task.sleep(for: .milliseconds(500))
                return .paneList([])
            case .teamMessage:
                teamRequestsHandled.value += 1
                return .ok
            default:
                return .error("unexpected")
            }
        }
        try server.start()
        defer { server.stop() }

        let oldRequest = Task.detached {
            try Self.exchangeRequests(
                socketPath: socketPath,
                jsonLines: [
                    #"{"type":"list_panes","path":"/tmp/slow"}"#,
                    #"{"type":"team_message","caller_worktree":"/tmp/old","recipient":"peer","text":"stale"}"#,
                ]
            )
        }
        try await expectSignal(from: slowStarts)

        server.stop()
        try server.start()
        #expect(
            try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"team_message","caller_worktree":"/tmp/new","recipient":"peer","text":"current"}"#
            ) == .ok
        )
        #expect((try await oldRequest.value).isEmpty)
        #expect(teamRequestsHandled.value == 1)
    }

    @Test func serverOmitsResponseWhenOnRequestUnset() async throws {
        // Fire-and-forget path must still work — notify/clear don't expect replies.
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-fnf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let (messages, messageContinuation) = AsyncStream.makeStream(of: NotificationMessage.self)
        defer { messageContinuation.finish() }
        let server = SocketServer(socketPath: socketPath)
        server.onMessage = { messageContinuation.yield($0) }
        // Intentionally no onRequest.
        try server.start()
        defer { server.stop() }

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

        _ = try await expectMessage(from: messages)
    }

    @Test("""
    @spec ATTN-2.20: When the application receives a one-way `notify` or `clear` socket message, it shall dispatch the notification without registering or waiting on a response handler, so notification bursts cannot consume request-client capacity.
    """, arguments: [
        NotificationMessage.notify(
            path: "/tmp/wt",
            text: "hi",
            clearAfter: nil,
            paneSessionName: nil
        ),
        NotificationMessage.clear(path: "/tmp/wt", paneSessionName: nil),
    ])
    func fireAndForgetMessagesBypassAsyncResponseWaiters(
        message: NotificationMessage
    ) async throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "graftty-fnf-wait-\(UUID().uuidString.prefix(8))"
        )
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        let (messages, messageContinuation) = AsyncStream.makeStream(
            of: NotificationMessage.self
        )
        defer { messageContinuation.finish() }

        let server = SocketServer(socketPath: socketPath)
        server.maxConcurrentClients = 1
        server.onMessage = { messageContinuation.yield($0) }
        server.onAsyncRequest = { message in
            switch message {
            case .notify, .clear:
                try? await Task.sleep(for: .seconds(2))
                return nil
            default:
                return .ok
            }
        }
        try server.start()
        defer { server.stop() }

        let notifyFD = try Self.connectSocket(to: socketPath)
        let encodedMessage = try JSONEncoder().encode(message)
        try SocketIO.writeAll(
            fd: notifyFD,
            string: String(decoding: encodedMessage, as: UTF8.self) + "\n"
        )
        close(notifyFD)
        _ = try await expectMessage(from: messages)

        var response: ResponseMessage?
        for _ in 0..<20 {
            response = try Self.sendRequest(
                socketPath: socketPath,
                json: #"{"type":"team_list","caller_worktree":"/tmp/wt"}"#
            )
            if response == .ok { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(response == .ok)
    }

    @Test("""
    @spec ATTN-2.21: When the application accepts a control-socket client, it shall bound both receive and send I/O so a silent or non-reading peer cannot retain client capacity indefinitely.
    """)
    func acceptedClientSocketIOIsBounded() throws {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }

        #expect(SocketServer.configureAcceptedSocket(
            sockets[0],
            receiveTimeoutSeconds: 1,
            sendTimeoutSeconds: 1
        ))

        var configuredSendTimeout = timeval()
        var configuredSendTimeoutSize = socklen_t(
            MemoryLayout<timeval>.size
        )
        #expect(getsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_SNDTIMEO,
            &configuredSendTimeout,
            &configuredSendTimeoutSize
        ) == 0)
        #expect(configuredSendTimeout.tv_sec == 1)

        var sendBufferBytes: Int32 = 1_024
        #expect(setsockopt(
            sockets[0],
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferBytes,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0)

        let payload = [UInt8](repeating: 0x41, count: 1 * 1024 * 1024)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: SocketIO.WriteError.self) {
            try payload.withUnsafeBufferPointer { buffer in
                try SocketIO.writeAll(
                    fd: sockets[0],
                    bytes: buffer.baseAddress!,
                    count: buffer.count
                )
            }
        }
        let elapsed = started.duration(to: clock.now)
        #expect(
            elapsed >= .milliseconds(750) && elapsed < .seconds(5),
            "configured send deadline did not bound the write: \(elapsed)"
        )
    }

    /// `onRequest` runs on the main queue; if the main actor stalls (modal
    /// dialog, long synchronous work, a reentrancy bug), its connection would
    /// otherwise remain open forever. The handler no longer occupies a socket
    /// worker while suspended, but every request still needs a bounded terminal
    /// condition.
    ///
    /// The server shall cap its wait with a bounded timeout and, on expiry,
    /// close the client fd without a response. Observable: the client's
    /// `read()` sees EOF within the server's timeout window + small margin,
    /// not after onRequest's full duration.
    @Test("""
    @spec ATTN-2.10: When a request-style socket message hands its handler to the main actor, the application shall wait at most `SocketServer.onRequestTimeout` (5 seconds in production) before terminating that client connection without a response, and neither later request lines nor a handler that completes late shall write to the closed connection.
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
        let (handlerStarts, handlerStartContinuation) = AsyncStream.makeStream(
            of: Void.self
        )
        defer { handlerStartContinuation.finish() }
        defer { gate.signal() }
        server.onRequest = { _ in
            handlerStartContinuation.yield(())
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

        let msg = #"{"type":"team_list","caller_worktree":"/tmp/wt"}"# + "\n"
        msg.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
        // Half-close write side so the server's read loop exits
        // immediately (EOF) rather than waiting out its 2s
        // SO_RCVTIMEO (cycle 131 ATTN-2.9). Keep read side open so
        // we can observe EOF from server-initiated close.
        shutdown(fd, Int32(SHUT_WR))
        try await expectSignal(from: handlerStarts, timeout: .seconds(1))

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
    @spec ATTN-2.9: When the application accepts a client connection, it shall set `SO_RCVTIMEO` to 2 seconds before reading so a silent peer releases its connection worker and fd within a bounded interval. The deadline shall remain per-client so one silent peer does not delay independent connections.
    """)
    func silentClientDoesNotBlockOtherClients() async throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-hang-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let socketPath = dir.appendingPathComponent("s").path
        // The callback is the synchronization point for the independent
        // client; socket state below proves it arrived before the silent
        // client's own deadline without a tight wall-clock threshold.
        let (events, eventContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { eventContinuation.finish() }

        let server = SocketServer(socketPath: socketPath)
        #expect(server.clientReadTimeoutSeconds == 2)
        server.clientReadTimeoutSeconds = 1
        server.onMessage = { _ in eventContinuation.yield(()) }
        try server.start()
        defer { server.stop() }

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
        let clock = ContinuousClock()
        let silentConnectedAt = clock.now
        let silentFD = connectClient()
        defer { close(silentFD) }
        var rcvTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(
            silentFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &rcvTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        // Give the server a beat to accept + begin handling #1.
        try await Task.sleep(for: .milliseconds(100))

        // Connection #2: valid — write one message and close.
        let activeFD = connectClient()
        let msg = #"{"type":"notify","path":"/tmp/wt","text":"test"}"# + "\n"
        msg.withCString { ptr in _ = Darwin.write(activeFD, ptr, strlen(ptr)) }
        close(activeFD)

        try await expectSignal(from: events)
        var peekByte: UInt8 = 0
        errno = 0
        let peekResult = Darwin.recv(
            silentFD,
            &peekByte,
            1,
            Int32(MSG_PEEK | MSG_DONTWAIT)
        )
        let peekErrno = errno
        #expect(
            peekResult == -1
                && (peekErrno == EAGAIN || peekErrno == EWOULDBLOCK),
            "silent socket closed before the independent callback"
        )

        // Independently prove the silent connection carries its configured
        // per-client deadline. The production value is pinned above; using a
        // one-second override keeps this behavioral check fast and precise.
        var buffer = [UInt8](repeating: 0, count: 1)
        let bytesRead = Darwin.read(silentFD, &buffer, buffer.count)
        let silentLifetime = silentConnectedAt.duration(to: clock.now)
        #expect(bytesRead == 0, "silent connection must close at its read deadline")
        #expect(
            silentLifetime >= .milliseconds(750)
                && silentLifetime < .seconds(2),
            "expected the 1s test deadline; silent client lived for \(silentLifetime)"
        )
    }

    private struct MessageTimeoutError: Error {}

    private static func sendRequest(
        socketPath: String,
        json: String
    ) throws -> ResponseMessage {
        guard let response = try sendRequests(
            socketPath: socketPath,
            jsonLines: [json]
        ).first else {
            throw POSIXError(.ECONNRESET)
        }
        return response
    }

    private static func sendRequests(
        socketPath: String,
        jsonLines: [String]
    ) throws -> [ResponseMessage] {
        let buffer = try exchangeRequests(
            socketPath: socketPath,
            jsonLines: jsonLines
        )
        guard !buffer.isEmpty else { throw POSIXError(.ECONNRESET) }
        return try String(decoding: buffer, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try JSONDecoder().decode(
                    ResponseMessage.self,
                    from: Data(line.utf8)
                )
            }
    }

    private static func exchangeRequests(
        socketPath: String,
        jsonLines: [String]
    ) throws -> Data {
        let fd = try connectSocket(to: socketPath)
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let payload = jsonLines.joined(separator: "\n") + "\n"
        try SocketIO.writeAll(fd: fd, string: payload)
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))
        return SocketIO.readAll(fd: fd, cap: 1 * 1024 * 1024)
    }

    private static func connectSocket(to socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(
                    to: CChar.self,
                    capacity: 104
                ) { destination in
                    _ = strlcpy(destination, ptr, 104)
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    fd,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connected == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }

        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        return fd
    }

    private func expectSignal(
        from stream: AsyncStream<Void>,
        timeout: Duration = .seconds(5)
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            guard try await group.next() == true else {
                throw MessageTimeoutError()
            }
        }
    }

    private func expectMessage(
        from stream: AsyncStream<NotificationMessage>,
        timeout: Duration = .seconds(20)
    ) async throws -> NotificationMessage {
        try await withThrowingTaskGroup(of: NotificationMessage?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let message = try await group.next() ?? nil else {
                throw MessageTimeoutError()
            }
            return message
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

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
