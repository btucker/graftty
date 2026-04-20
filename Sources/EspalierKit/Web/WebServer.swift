import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

/// HTTP + WebSocket server for Phase 2 web access. Binds to each
/// Tailscale IP (plus 127.0.0.1), serves static assets at `/`,
/// upgrades `/ws?session=<name>` to WebSocket, and gates both
/// paths via `AuthPolicy.isAllowed(peerIP:)`.
public final class WebServer {

    public enum Status: Equatable {
        case stopped
        case listening(addresses: [String], port: Int)
        case disabledNoTailscale
        case portUnavailable
        case error(String)
    }

    /// One entry served by `GET /sessions`. Minimum useful shape for the
    /// client's session picker (`WEB-5.4`): the `name` is the URL segment
    /// under `/session/`, and the label hints let the picker disambiguate
    /// multiple worktrees sharing a directory basename.
    public struct SessionInfo: Codable, Sendable, Equatable {
        public let name: String
        public let worktreePath: String
        public let repoDisplayName: String
        public let worktreeDisplayName: String

        public init(
            name: String,
            worktreePath: String,
            repoDisplayName: String,
            worktreeDisplayName: String
        ) {
            self.name = name
            self.worktreePath = worktreePath
            self.repoDisplayName = repoDisplayName
            self.worktreeDisplayName = worktreeDisplayName
        }
    }

    public struct Config {
        public let port: Int
        public let zmxExecutable: URL
        public let zmxDir: URL
        /// Source for `GET /sessions`. Called on each request; runs fast
        /// because the list is read from in-memory AppState (no git work).
        public let sessionsProvider: @Sendable () async -> [SessionInfo]

        public init(
            port: Int,
            zmxExecutable: URL,
            zmxDir: URL,
            sessionsProvider: @escaping @Sendable () async -> [SessionInfo] = { [] }
        ) {
            self.port = port
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
            self.sessionsProvider = sessionsProvider
        }

        /// Accepts the range NIO's `bootstrap.bind(host:port:)` will accept
        /// without throwing: 0 (kernel-assigned ephemeral — integration
        /// tests rely on this) through 65535 (`UInt16.max`). Negative
        /// values and values ≥ 65536 are rejected.
        ///
        /// `WebServerController` runs `WebAccessSettings.port` through this
        /// gate before constructing the `Config` — without it, user input
        /// like "99999" would surface as an opaque `NIOBindError` in the
        /// Settings pane status row (`WEB-1.5`).
        public static func isValidListenablePort(_ port: Int) -> Bool {
            (0...65535).contains(port)
        }
    }

    /// Decides whether a given peer IP is allowed. Pluggable so tests
    /// can inject a permissive stub without real Tailscale.
    public struct AuthPolicy {
        public let isAllowed: @Sendable (String) async -> Bool
        public init(isAllowed: @escaping @Sendable (String) async -> Bool) { self.isAllowed = isAllowed }
    }

    public private(set) var status: Status = .stopped
    public let config: Config
    public let auth: AuthPolicy
    public let bindAddresses: [String]

    /// Test-only hook: when non-nil, applied as `SO_SNDBUF` on every child
    /// (accepted) channel. Exists to simulate buffer-constrained network
    /// paths like the Tailscale `utun` interface where
    /// `ERR_CONTENT_LENGTH_MISMATCH` was first observed — on loopback the
    /// kernel's huge auto-sized send buffers always swallow the full
    /// response in one go, so the bug is invisible without shrinking the
    /// socket buffer. Unused in production.
    internal static var testingChildSndBuf: Int?

    private var group: EventLoopGroup?
    private var channels: [Channel] = []

    public init(config: Config, auth: AuthPolicy, bindAddresses: [String]) {
        self.config = config
        self.auth = auth
        self.bindAddresses = bindAddresses
    }

    public func start() throws {
        precondition(group == nil, "WebServer already started")
        guard !bindAddresses.isEmpty else {
            status = .disabledNoTailscale
            throw Status.disabledNoTailscale.asError
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group

        let capturedConfig = config
        let capturedAuth = auth

        var bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        if let sndBuf = Self.testingChildSndBuf {
            bootstrap = bootstrap.childChannelOption(
                ChannelOptions.socketOption(.so_sndbuf), value: .init(sndBuf)
            )
        }
        bootstrap = bootstrap
            .childChannelInitializer { channel in
                let handler = HTTPHandler(config: capturedConfig, auth: capturedAuth)
                let upgrader = Self.makeWSUpgrader(config: capturedConfig, auth: capturedAuth)
                // After a successful WebSocket upgrade, the HTTP encoder/decoder
                // are removed by NIO, but our `HTTPHandler` (added below) stays
                // in the pipeline and would receive raw WebSocketFrames — which
                // it can't decode, crashing with a "tried to decode as type
                // HTTPPart" fatalError. Remove it in the completion handler so
                // the WebSocketBridgeHandler is the only inbound handler after
                // upgrade.
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in
                        context.channel.pipeline.removeHandler(handler, promise: nil)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: upgradeConfig
                ).flatMap {
                    channel.pipeline.addHandler(handler)
                }
            }

        do {
            channels = try bindAddresses.map { try bootstrap.bind(host: $0, port: config.port).wait() }
        } catch {
            try? group.syncShutdownGracefully()
            self.group = nil
            let ns = (error as NSError)
            if ns.domain.contains("posix") || "\(error)".contains("EADDRINUSE") {
                status = .portUnavailable
            } else {
                status = .error("\(error)")
            }
            throw error
        }
        // When config.port == 0, the kernel assigns an ephemeral port; read it
        // back from the first bound channel so callers can discover the actual
        // listening port. If multiple binds produce different ports (not
        // expected with a fixed non-zero port, but defensible), the first one
        // wins.
        let actualPort = channels.first?.localAddress?.port ?? config.port
        status = .listening(addresses: bindAddresses, port: actualPort)
    }

    public func stop() {
        for c in channels { try? c.close().wait() }
        channels.removeAll()
        try? group?.syncShutdownGracefully()
        group = nil
        status = .stopped
    }

    // MARK: - WS upgrader factory

    private static func makeWSUpgrader(config: Config, auth: AuthPolicy) -> NIOWebSocketServerUpgrader {
        return NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                guard head.uri.hasPrefix("/ws") else {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                let peer = channel.remoteAddress?.ipAddress ?? "unknown"
                let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                channel.eventLoop.execute {
                    Task {
                        let allowed = await auth.isAllowed(peer)
                        promise.succeed(allowed ? HTTPHeaders() : nil)
                    }
                }
                return promise.futureResult
            },
            upgradePipelineHandler: { channel, head in
                let session = Self.parseSession(from: head.uri)
                let wsHandler = WebSocketBridgeHandler(
                    sessionName: session,
                    zmxExecutable: config.zmxExecutable,
                    zmxDir: config.zmxDir
                )
                return channel.pipeline.addHandler(wsHandler)
            }
        )
    }

    private static func parseSession(from uri: String) -> String {
        guard let q = uri.split(separator: "?").dropFirst().first else { return "" }
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2, kv[0] == "session" {
                return String(kv[1]).removingPercentEncoding ?? String(kv[1])
            }
        }
        return ""
    }

    // MARK: - HTTP handler

    // @unchecked Sendable: NIO serializes handler callbacks onto a single
    // event loop, so `currentRequestHead` is thread-confined in practice.
    // The upgrade completionHandler closure requires Sendable capture.
    private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        let config: Config
        let auth: AuthPolicy
        var currentRequestHead: HTTPRequestHead?

        init(config: Config, auth: AuthPolicy) {
            self.config = config
            self.auth = auth
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch part {
            case .head(let head):
                currentRequestHead = head
            case .body:
                break
            case .end:
                guard let head = currentRequestHead else { return }
                currentRequestHead = nil
                let peer = context.channel.remoteAddress?.ipAddress ?? "unknown"
                let loop = context.eventLoop
                let promise = loop.makePromise(of: Bool.self)
                let auth = self.auth
                loop.execute {
                    Task {
                        let allowed = await auth.isAllowed(peer)
                        promise.succeed(allowed)
                    }
                }
                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    let allowed = (try? result.get()) ?? false
                    if !allowed {
                        Self.respond(context: context, status: .forbidden, body: Data("forbidden\n".utf8), contentType: "text/plain; charset=utf-8")
                        return
                    }
                    self.serveStatic(context: context, head: head)
                }
            }
        }

        func serveStatic(context: ChannelHandlerContext, head: HTTPRequestHead) {
            let path = head.uri.split(separator: "?").first.map(String.init) ?? "/"
            // /ws paths are reserved for WebSocket upgrade; never fall through to
            // the SPA index for plain HTTP requests on those paths.
            if path == "/ws" || path.hasPrefix("/ws/") {
                Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
                return
            }
            // WEB-5.4: session list endpoint for the client's minimal picker.
            if path == "/sessions" {
                let eventLoop = context.eventLoop
                let provider = config.sessionsProvider
                let promise = eventLoop.makePromise(of: [SessionInfo].self)
                eventLoop.execute {
                    Task {
                        let sessions = await provider()
                        promise.succeed(sessions)
                    }
                }
                promise.futureResult.whenComplete { result in
                    let sessions = (try? result.get()) ?? []
                    do {
                        let data = try JSONEncoder().encode(sessions)
                        Self.respond(
                            context: context,
                            status: .ok,
                            body: data,
                            contentType: "application/json; charset=utf-8"
                        )
                    } catch {
                        Self.respond(
                            context: context,
                            status: .internalServerError,
                            body: Data("encoding error\n".utf8),
                            contentType: "text/plain; charset=utf-8"
                        )
                    }
                }
                return
            }
            do {
                let asset = try WebStaticResources.asset(for: path)
                Self.respond(context: context, status: .ok, body: asset.data, contentType: asset.contentType)
            } catch WebStaticResources.Error.missingResource {
                // SPA fallback: any non-asset path returns index.html so
                // TanStack Router can resolve client-side routes like
                // /session/<name> when loaded directly by the browser.
                do {
                    let index = try WebStaticResources.indexHTML()
                    Self.respond(context: context, status: .ok, body: index.data, contentType: index.contentType)
                } catch {
                    Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
                }
            } catch {
                Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
            }
        }

        static func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, contentType: String) {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: "\(body.count)")
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: status, headers: headers)
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
            // Chain `close` off the end-of-response flush promise. NIO's
            // `close0(mode: .all)` cancels any writes still pending in
            // `PendingWritesManager` *after* closing the socket fd, so
            // closing synchronously after `writeAndFlush(..., promise: nil)`
            // truncates the body whenever the kernel's TCP send buffer
            // can't absorb the whole response in one pass — which is the
            // normal case on Tailscale's `utun` (MTU ~1280) and the root
            // cause of `ERR_CONTENT_LENGTH_MISMATCH` on `/app.js`.
            let donePromise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: donePromise)
            donePromise.futureResult.whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }

    // MARK: - WebSocket bridge handler

    private final class WebSocketBridgeHandler: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame

        let sessionName: String
        let zmxExecutable: URL
        let zmxDir: URL
        private var session: WebSession?
        private weak var channel: Channel?

        init(sessionName: String, zmxExecutable: URL, zmxDir: URL) {
            self.sessionName = sessionName
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
        }

        func handlerAdded(context: ChannelHandlerContext) {
            channel = context.channel
            let sess = WebSession(config: WebSession.Config(
                zmxExecutable: zmxExecutable,
                zmxDir: zmxDir,
                sessionName: sessionName
            ))
            sess.onPTYData = { [weak self] data in
                guard let self, let channel = self.channel else { return }
                channel.eventLoop.execute {
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                    channel.writeAndFlush(frame, promise: nil)
                }
            }
            sess.onExit = { [weak self] in
                guard let self, let channel = self.channel else { return }
                channel.eventLoop.execute {
                    let close = WebSocketFrame(
                        fin: true,
                        opcode: .connectionClose,
                        data: channel.allocator.buffer(capacity: 0)
                    )
                    channel.writeAndFlush(close, promise: nil)
                    channel.close(promise: nil)
                }
            }
            do {
                try sess.start()
                session = sess
            } catch {
                let errMsg = #"{"type":"error","message":"session unavailable"}"#
                var buf = context.channel.allocator.buffer(capacity: errMsg.utf8.count)
                buf.writeString(errMsg)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                context.writeAndFlush(NIOAny(frame), promise: nil)
                context.close(promise: nil)
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .binary:
                var buf = frame.unmaskedData
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    session?.write(Data(bytes))
                }
            case .text:
                var buf = frame.unmaskedData
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    let payload = Data(bytes)
                    if let env = try? WebControlEnvelope.parse(payload) {
                        if case let .resize(cols, rows) = env {
                            session?.resize(cols: cols, rows: rows)
                        }
                    }
                }
            case .connectionClose:
                session?.close()
                context.close(promise: nil)
            case .ping:
                let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
                context.writeAndFlush(NIOAny(pong), promise: nil)
            default:
                break
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            session?.close()
        }
    }
}

private extension WebServer.Status {
    var asError: Swift.Error {
        NSError(domain: "WebServer", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(self)"])
    }
}
