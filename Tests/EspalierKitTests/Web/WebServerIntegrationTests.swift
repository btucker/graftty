import Testing
import Foundation
@testable import EspalierKit

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
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }

        let sessionName = "espalier-it\(UUID().uuidString.prefix(6).lowercased())"
        let url = URL(string: "ws://127.0.0.1:\(port)/ws?session=\(sessionName)")!
        let wsTask = URLSession.shared.webSocketTask(with: url)
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
