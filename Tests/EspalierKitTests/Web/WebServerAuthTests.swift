import Testing
import Foundation
@testable import EspalierKit

@Suite("WebServer — auth gate", .serialized)
struct WebServerAuthTests {

    private static func makeConfig(port: Int = 0) -> WebServer.Config {
        WebServer.Config(
            port: port,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp")
        )
    }

    @Test func deniedRequestReturns403() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in false }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 403)
    }

    @Test func allowedRequestServesHTML() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = String(data: data, encoding: .utf8) ?? ""
        #expect(html.contains("<div id=\"root\">"))
    }

    @Test func spaFallbackServesIndexForUnknownPath() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/session/whatever")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("<div id=\"root\">"), "SPA fallback should serve index.html body")
    }

    @Test func wsPathReturns404WithoutUpgradeHeader() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/ws")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 404, "/ws without Upgrade must NOT fall through to index.html")
    }

    @Test func servesAppJS() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/app.js")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/javascript; charset=utf-8")
        #expect(data.count > 100)
    }

    /// Regression for `bug-web-content-length-mismatch`: serving a large
    /// bundled asset like `app.js` (~318KB) must deliver the full declared
    /// `Content-Length` of bytes, all the way to EOF on a raw TCP read.
    /// The original server closed the channel immediately after
    /// `writeAndFlush` without waiting on the flush promise, so TCP send
    /// buffers that couldn't hold the whole body in one shot led Chrome
    /// to surface `ERR_CONTENT_LENGTH_MISMATCH`.
    @Test func appJSRawReadMatchesContentLength() async throws {
        // Shrink the server's child-channel SO_SNDBUF so the ~318KB body
        // can't be handed to the kernel in one shot; this forces NIO to
        // keep bytes in its own `PendingWritesManager`, exposing the race
        // where `context.close(promise: nil)` runs before the flush
        // completes. Without this knob the bug is invisible on loopback.
        WebServer.testingChildSndBuf = 2048
        defer { WebServer.testingChildSndBuf = nil }

        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let expected = try WebStaticResources.asset(for: "/app.js").data.count

        let (headers, body) = try rawHTTPGet(
            host: "127.0.0.1", port: port, path: "/app.js",
            recvBufBytes: 2048, perReadDelayUSec: 1_000
        )
        let declared = headers["content-length"].flatMap(Int.init)
        #expect(declared == expected, "declared Content-Length \(declared ?? -1) != resource size \(expected)")
        #expect(body.count == expected,
                "raw-socket read got \(body.count) bytes but Content-Length declared \(expected) — truncated")
    }

    @Test func appJSBodyLengthMatchesContentLength() async throws {
        let server = WebServer(
            config: Self.makeConfig(),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let expected = try WebStaticResources.asset(for: "/app.js").data.count
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/app.js")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "\(expected)")
        #expect(data.count == expected,
                "expected full \(expected) bytes, got \(data.count) — content-length mismatch")
    }
}

/// Minimal synchronous HTTP/1.1 GET over a raw POSIX socket. Reads until
/// the server closes the connection (we set `Connection: close`) and
/// returns parsed lowercased response headers plus the raw body bytes.
/// Used to verify the server actually transmits the number of body bytes
/// declared in its `Content-Length` header — higher-level clients like
/// `URLSession` can silently tolerate short bodies on localhost.
private func rawHTTPGet(
    host: String, port: Int, path: String,
    recvBufBytes: Int? = nil, perReadDelayUSec: UInt32 = 0
) throws -> (headers: [String: String], body: Data) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { close(fd) }

    if var size = recvBufBytes.map(Int32.init) {
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else { throw POSIXError(.ECONNREFUSED) }

    let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
    let reqData = Data(request.utf8)
    _ = reqData.withUnsafeBytes { buf in
        send(fd, buf.baseAddress, buf.count, 0)
    }

    // Small read chunks keep the socket's receive buffer from draining
    // faster than the server can refill it; combined with a clamped
    // SO_RCVBUF this reliably backs up the server's TCP send queue.
    var all = Data()
    var tmp = [UInt8](repeating: 0, count: 1024)
    while true {
        let n = tmp.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
        if n <= 0 { break }
        all.append(tmp, count: n)
        if perReadDelayUSec > 0 { usleep(perReadDelayUSec) }
    }

    guard let sep = all.range(of: Data("\r\n\r\n".utf8)) else {
        throw POSIXError(.EPROTO)
    }
    let headerBlock = String(data: all.subdata(in: 0..<sep.lowerBound), encoding: .utf8) ?? ""
    let body = all.subdata(in: sep.upperBound..<all.endIndex)
    var headers: [String: String] = [:]
    for line in headerBlock.split(separator: "\r\n").dropFirst() {
        if let colon = line.firstIndex(of: ":") {
            let k = line[..<colon].lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(k)] = v
        }
    }
    return (headers, body)
}
