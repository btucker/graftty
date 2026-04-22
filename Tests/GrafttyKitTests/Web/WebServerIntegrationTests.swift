import Testing
import Foundation
@testable import GrafttyKit

@Suite("WebServer — integration (requires vendored zmx)")
struct WebServerIntegrationTests {

    /// Allocate an isolated ZMX_DIR under `/tmp` (see
    /// `ZmxSurvivalIntegrationTests.withScopedZmxDir` for why `/tmp` rather
    /// than `NSTemporaryDirectory()` — the 104-byte Unix-socket path limit).
    private static func scopedZmxDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("zmx-web-it-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `WEB-5.6`: The server must handle a client dropping its WebSocket
    /// and then immediately reopening one to the same session name —
    /// which is what the client does on visibility-change or on a
    /// network wobble. The daemon session survives per WEB-4.5; only
    /// the `zmx attach` child is SIGTERM'd, so a second attach to the
    /// same session must succeed.
    ///
    /// Why this test exists: the client's auto-reconnect loop is
    /// worthless if the server can't accept the reconnected socket. We
    /// don't have JS test infrastructure to exercise the client loop
    /// directly, but this test covers the server-side contract the
    /// client relies on.
    @Test func wsReconnectToSameSessionSucceeds() async throws {
        if ProcessInfo.processInfo.environment["CI"] != nil { return }
        let zmx = try #require(
            ZmxSurvivalIntegrationTests.vendoredZmx(),
            "zmx binary not vendored — run scripts/bump-zmx.sh"
        )
        let zmxDir = try Self.scopedZmxDir()
        defer { try? FileManager.default.removeItem(at: zmxDir) }

        let server = WebServer(
            config: WebServer.Config(port: 0, zmxExecutable: zmx, zmxDir: zmxDir),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }

        let sessionName = "graftty-it\(UUID().uuidString.prefix(6).lowercased())"
        let url = URL(string: "wss://localhost:\(port)/ws?session=\(sessionName)")!

        // First attach — creates the daemon session.
        let wsSession = trustAllSession()
        let first = wsSession.webSocketTask(with: url)
        first.resume()
        try await first.send(.string(#"{"type":"resize","cols":80,"rows":24}"#))
        try await first.send(.data(Data("echo ONE\n".utf8)))

        // Drain until we see the marker, then hang up — the server's
        // channelInactive runs SIGTERM on the attach child but leaves
        // the daemon session alive per WEB-4.5.
        _ = try await Self.readUntil(task: first, marker: "ONE", deadline: 8.0)
        first.cancel(with: .goingAway, reason: nil)

        // Give the server a moment to reap the attach child. The
        // daemon session survives; a new WebSocket should be able to
        // re-attach by name.
        try await Task.sleep(nanoseconds: 500_000_000)

        let second = wsSession.webSocketTask(with: url)
        second.resume()
        try await second.send(.string(#"{"type":"resize","cols":80,"rows":24}"#))
        try await second.send(.data(Data("echo TWO\n".utf8)))
        let text = try await Self.readUntil(task: second, marker: "TWO", deadline: 8.0)
        #expect(text.contains("TWO"),
                "reconnected WebSocket should see its own echo — saw \(text.count) bytes")
        second.cancel(with: .goingAway, reason: nil)

        // Clean up the daemon session so this test doesn't leak state.
        let launcher = ZmxLauncher(executable: zmx, zmxDir: zmxDir)
        launcher.kill(sessionName: sessionName)
    }

    /// Read from a WebSocketTask until `marker` is seen or `deadline`
    /// seconds elapse. Returns the accumulated string (may be partial
    /// at deadline). Extracted so the reconnect test can reuse the same
    /// "wait for echo" pattern the original round-trip test introduced.
    private static func readUntil(
        task: URLSessionWebSocketTask,
        marker: String,
        deadline seconds: Double
    ) async throws -> String {
        let cancelTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { cancelTask.cancel() }

        var collected = Data()
        while true {
            let msg: URLSessionWebSocketTask.Message
            do {
                msg = try await task.receive()
            } catch {
                break
            }
            switch msg {
            case .data(let d): collected.append(d)
            case .string(let s): collected.append(Data(s.utf8))
            @unknown default: break
            }
            if let s = String(data: collected, encoding: .utf8), s.contains(marker) { break }
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    @Test func wsEchoRoundTrip() async throws {
        // Skipped in CI until the end-to-end zmx-attach + NIO + URLSession
        // WebSocket path is hardened against environment quirks that
        // manifest on GitHub Actions runners (see PR #14 discussion). The
        // WebServer → WebSession → PtyProcess unit path is covered by
        // WebServerAuthTests + WebStaticResourcesTests + PtyProcessTests.
        //
        // Plain early-return rather than `#require` because Swift Testing
        // treats `#require` failure as a test failure, not a skip.
        if ProcessInfo.processInfo.environment["CI"] != nil { return }
        let zmx = try #require(
            ZmxSurvivalIntegrationTests.vendoredZmx(),
            "zmx binary not vendored — run scripts/bump-zmx.sh"
        )
        let zmxDir = try Self.scopedZmxDir()
        defer { try? FileManager.default.removeItem(at: zmxDir) }

        let server = WebServer(
            config: WebServer.Config(port: 0, zmxExecutable: zmx, zmxDir: zmxDir),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }

        let sessionName = "graftty-it\(UUID().uuidString.prefix(6).lowercased())"
        let url = URL(string: "wss://localhost:\(port)/ws?session=\(sessionName)")!
        let wsTask = trustAllSession().webSocketTask(with: url)
        wsTask.resume()

        try await wsTask.send(.string(#"{"type":"resize","cols":80,"rows":24}"#))
        try await wsTask.send(.data(Data("echo HELLO_INTEG\n".utf8)))

        // URLSessionWebSocketTask.receive() blocks until a frame arrives —
        // there's no built-in timeout. If `zmx attach` hangs or the PTY
        // produces no output (seen on CI), receive() blocks forever and
        // the per-loop `Date() < deadline` check never runs. Schedule an
        // out-of-band cancel at the deadline so receive() throws and we
        // exit cleanly.
        let cancelTask = Task {
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            wsTask.cancel(with: .goingAway, reason: nil)
        }
        defer { cancelTask.cancel() }

        var collected = Data()
        while true {
            let msg: URLSessionWebSocketTask.Message
            do {
                msg = try await wsTask.receive()
            } catch {
                break
            }
            switch msg {
            case .data(let d): collected.append(d)
            case .string(let s): collected.append(Data(s.utf8))
            @unknown default: break
            }
            if let s = String(data: collected, encoding: .utf8), s.contains("HELLO_INTEG") { break }
        }
        let text = String(data: collected, encoding: .utf8) ?? ""
        #expect(text.contains("HELLO_INTEG"))

        wsTask.cancel(with: .goingAway, reason: nil)

        // Best-effort clean up the session.
        let launcher = ZmxLauncher(executable: zmx, zmxDir: zmxDir)
        launcher.kill(sessionName: sessionName)
    }
}
