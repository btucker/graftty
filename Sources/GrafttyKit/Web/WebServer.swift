import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOWebSocket

/// HTTP + WebSocket server for Phase 2 web access. Binds to each
/// Tailscale IP (plus 127.0.0.1), serves static assets at `/`,
/// upgrades `/ws?session=<name>` to WebSocket, and gates both
/// paths via `AuthPolicy.isAllowed(peerIP:)`.
public final class WebServer {

    public enum Status: Equatable {
        case stopped
        case listening(addresses: [String], port: Int)
        case tailscaleUnavailable
        case magicDNSDisabled
        case httpsCertsNotEnabled
        case certFetchFailed(String)
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

    /// One entry served by `GET /repos` — the set of repositories the
    /// web user can create a new worktree under, mirroring the native
    /// sidebar's repo disclosures. `path` is opaque to the client and
    /// round-tripped as `repoPath` on `POST /worktrees` so the server
    /// doesn't have to re-derive it from a display name (which could
    /// collide when two repos share a basename).
    public struct RepoInfo: Codable, Sendable, Equatable {
        public let path: String
        public let displayName: String

        public init(path: String, displayName: String) {
            self.path = path
            self.displayName = displayName
        }
    }

    /// JSON shape accepted by `POST /worktrees`.
    public struct CreateWorktreeRequest: Codable, Sendable, Equatable {
        public let repoPath: String
        public let worktreeName: String
        public let branchName: String

        public init(repoPath: String, worktreeName: String, branchName: String) {
            self.repoPath = repoPath
            self.worktreeName = worktreeName
            self.branchName = branchName
        }
    }

    /// JSON shape returned by `POST /worktrees` on success. Callers
    /// navigate to `/session/<sessionName>` to attach to the first pane
    /// of the new worktree.
    public struct CreateWorktreeResponse: Codable, Sendable, Equatable {
        public let sessionName: String
        public let worktreePath: String

        public init(sessionName: String, worktreePath: String) {
            self.sessionName = sessionName
            self.worktreePath = worktreePath
        }
    }

    /// Outcome a `worktreeCreator` reports back. Success carries the
    /// session name to steer the client to; failure carries the
    /// user-visible message (typically `git worktree add`'s stderr) and
    /// a coarse reason so the handler can pick the right HTTP status.
    public enum CreateWorktreeOutcome: Sendable {
        case success(CreateWorktreeResponse)
        case invalid(String)       // 400 — bad input (empty names, unknown repo)
        case gitFailed(String)     // 409 — `git worktree add` rejected the request
        case internalFailure(String) // 500 — post-success discovery or spawn broke
    }

    public struct Config {
        public let port: Int
        public let zmxExecutable: URL
        public let zmxDir: URL
        /// Source for `GET /sessions`. Called on each request; runs fast
        /// because the list is read from in-memory AppState (no git work).
        public let sessionsProvider: @Sendable () async -> [SessionInfo]
        /// Source for `GET /repos`. Same fast-snapshot contract as
        /// `sessionsProvider`: read from in-memory AppState, no git.
        public let reposProvider: @Sendable () async -> [RepoInfo]
        /// Executes `POST /worktrees`. Nil (default) means the endpoint
        /// is disabled — it responds `503` rather than `404` so the web
        /// client can tell "server doesn't support this yet" apart from
        /// "wrong URL". In production `GrafttyApp` always injects a real
        /// creator; the default exists for tests and early-boot states
        /// where `AppState` isn't wired yet.
        public let worktreeCreator: (@Sendable (CreateWorktreeRequest) async -> CreateWorktreeOutcome)?

        public init(
            port: Int,
            zmxExecutable: URL,
            zmxDir: URL,
            sessionsProvider: @escaping @Sendable () async -> [SessionInfo] = { [] },
            reposProvider: @escaping @Sendable () async -> [RepoInfo] = { [] },
            worktreeCreator: (@Sendable (CreateWorktreeRequest) async -> CreateWorktreeOutcome)? = nil
        ) {
            self.port = port
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
            self.sessionsProvider = sessionsProvider
            self.reposProvider = reposProvider
            self.worktreeCreator = worktreeCreator
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
    public let tlsProvider: WebTLSContextProvider

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

    public init(
        config: Config,
        auth: AuthPolicy,
        bindAddresses: [String],
        tlsProvider: WebTLSContextProvider
    ) {
        self.config = config
        self.auth = auth
        self.bindAddresses = bindAddresses
        self.tlsProvider = tlsProvider
    }

    public func start() throws {
        precondition(group == nil, "WebServer already started")
        guard !bindAddresses.isEmpty else {
            status = .tailscaleUnavailable
            throw Status.tailscaleUnavailable.asError
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group

        let capturedConfig = config
        let capturedAuth = auth
        let capturedTLS = tlsProvider

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
                // Snapshot the current TLS context at channel-accept time. Any
                // in-flight handshake uses this exact context even if a renewal
                // swaps the provider mid-handshake; that's fine — new connections
                // accepted after the swap pick up the fresh context on their
                // next initializer call. WEB-8.3.
                //
                // `NIOSSLServerHandler` is explicitly not `Sendable`, so we
                // add it via `pipeline.syncOperations` (which doesn't require
                // Sendable) rather than the async `pipeline.addHandler`. The
                // child-channel initializer runs on the accepting channel's
                // event loop (see `ServerBootstrap.AcceptHandler.channelRead`
                // in NIOPosix), so `syncOperations` is safe here.
                do {
                    let sslHandler = NIOSSLServerHandler(context: capturedTLS.current())
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
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
            if Self.isAddressInUse(error) {
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

    /// Recognise an "address already in use" bind failure across the
    /// shapes NIO surfaces it as. Bridged NSError POSIX errno is the
    /// locale-stable check; the string match is a fallback.
    public static func isAddressInUse(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EADDRINUSE) { return true }
        let s = "\(error)"
        return s.contains("EADDRINUSE") || s.contains("Address already in use")
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

        /// Cap accumulated request body before we give up. `POST /worktrees`
        /// accepts a tiny JSON object (~150 bytes); 64 KiB is ~400× larger
        /// than anything legitimate and a hard stop against a malicious
        /// loopback client streaming an endless body to pin server memory.
        /// Since every other route is a GET (no body), this cap never
        /// bites a real request.
        private static let maxBodyBytes = 64 * 1024

        let config: Config
        let auth: AuthPolicy
        var currentRequestHead: HTTPRequestHead?
        /// Accumulated request body for the current in-flight request.
        /// Cleared on `.end`. Short-circuited to "body too large" once
        /// we cross `maxBodyBytes`.
        var currentRequestBody: Data = Data()
        var bodyTooLarge: Bool = false

        init(config: Config, auth: AuthPolicy) {
            self.config = config
            self.auth = auth
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch part {
            case .head(let head):
                currentRequestHead = head
                currentRequestBody.removeAll(keepingCapacity: true)
                bodyTooLarge = false
            case .body(var buf):
                guard !bodyTooLarge else { return }
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    if currentRequestBody.count + bytes.count > Self.maxBodyBytes {
                        bodyTooLarge = true
                        currentRequestBody.removeAll(keepingCapacity: false)
                    } else {
                        currentRequestBody.append(contentsOf: bytes)
                    }
                }
            case .end:
                guard let head = currentRequestHead else { return }
                currentRequestHead = nil
                let body = currentRequestBody
                let wasTooLarge = bodyTooLarge
                currentRequestBody = Data()
                bodyTooLarge = false

                let peer = context.channel.remoteAddress?.ipAddress ?? "unknown"
                let loop = context.eventLoop
                let promise = loop.makePromise(of: Bool.self)
                let auth = self.auth
                // Register `whenComplete` *before* launching the Task so
                // a very-fast auth check can't succeed the promise before
                // the completion handler is hooked. Launch the Task
                // directly — `promise.succeed` hops to the event loop
                // internally, so wrapping the Task in
                // `eventLoop.execute` is redundant and turned out to
                // wedge on CI (macos-26) when nested bridges ran
                // back-to-back (auth → endpoint handler → respond).
                promise.futureResult.whenComplete { [weak self] result in
                    guard let self else { return }
                    let allowed = (try? result.get()) ?? false
                    if !allowed {
                        Self.respond(context: context, status: .forbidden, body: Data("forbidden\n".utf8), contentType: "text/plain; charset=utf-8")
                        return
                    }
                    if wasTooLarge {
                        Self.respondJSON(
                            context: context,
                            status: .payloadTooLarge,
                            error: "request body exceeds \(Self.maxBodyBytes) bytes"
                        )
                        return
                    }
                    self.serveStatic(context: context, head: head, body: body)
                }
                Task {
                    let allowed = await auth.isAllowed(peer)
                    promise.succeed(allowed)
                }
            }
        }

        func serveStatic(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
            let path = head.uri.split(separator: "?").first.map(String.init) ?? "/"
            // /ws paths are reserved for WebSocket upgrade; never fall through to
            // the SPA index for plain HTTP requests on those paths.
            if path == "/ws" || path.hasPrefix("/ws/") {
                Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
                return
            }
            // WEB-5.4: session list endpoint for the client's minimal picker.
            if path == "/sessions" {
                let provider = config.sessionsProvider
                let promise = context.eventLoop.makePromise(of: [SessionInfo].self)
                promise.futureResult.whenComplete { result in
                    let sessions = (try? result.get()) ?? []
                    Self.respondEncodable(context: context, items: sessions)
                }
                Task {
                    promise.succeed(await provider())
                }
                return
            }
            // WEB-7.1: repo list for the "Add Worktree" picker.
            if path == "/repos" {
                let provider = config.reposProvider
                let promise = context.eventLoop.makePromise(of: [RepoInfo].self)
                promise.futureResult.whenComplete { result in
                    let repos = (try? result.get()) ?? []
                    Self.respondEncodable(context: context, items: repos)
                }
                Task {
                    promise.succeed(await provider())
                }
                return
            }
            // WEB-7.2: create a new worktree. POST-only; other verbs get
            // 405 to keep caching proxies from surprising the client.
            if path == "/worktrees" {
                guard head.method == .POST else {
                    Self.respondJSON(
                        context: context,
                        status: .methodNotAllowed,
                        error: "only POST is supported"
                    )
                    return
                }
                handleCreateWorktree(context: context, body: body)
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

        /// Decode the JSON body, invoke the injected `worktreeCreator`,
        /// and map its `CreateWorktreeOutcome` to an HTTP status +
        /// `{error|sessionName+worktreePath}` JSON envelope. The handler
        /// is synchronous-style (no `Task` escaping the handler's scope
        /// beyond the awaited creator) and schedules the async work on
        /// the event loop so NIO's handler lifecycle stays predictable.
        private func handleCreateWorktree(context: ChannelHandlerContext, body: Data) {
            guard let creator = config.worktreeCreator else {
                Self.respondJSON(
                    context: context,
                    status: .serviceUnavailable,
                    error: "worktree creation not available"
                )
                return
            }
            let decoded: CreateWorktreeRequest
            do {
                decoded = try JSONDecoder().decode(CreateWorktreeRequest.self, from: body)
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "invalid JSON body: \(error)"
                )
                return
            }
            // Reject empty inputs here rather than letting git produce a
            // cryptic error. The name sanitizer runs client-side, but a
            // hand-crafted request could still arrive with whitespace
            // that trims to empty.
            let wtTrim = decoded.worktreeName.trimmingCharacters(in: .whitespaces)
            let brTrim = decoded.branchName.trimmingCharacters(in: .whitespaces)
            if decoded.repoPath.isEmpty || wtTrim.isEmpty || brTrim.isEmpty {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "repoPath, worktreeName, and branchName are required"
                )
                return
            }

            let promise = context.eventLoop.makePromise(of: CreateWorktreeOutcome.self)
            promise.futureResult.whenComplete { result in
                let outcome = (try? result.get()) ?? .internalFailure("creator dispatch failed")
                switch outcome {
                case .success(let resp):
                    do {
                        let data = try JSONEncoder().encode(resp)
                        Self.respond(
                            context: context,
                            status: .ok,
                            body: data,
                            contentType: "application/json; charset=utf-8"
                        )
                    } catch {
                        Self.respondJSON(
                            context: context,
                            status: .internalServerError,
                            error: "encoding error"
                        )
                    }
                case .invalid(let msg):
                    Self.respondJSON(context: context, status: .badRequest, error: msg)
                case .gitFailed(let msg):
                    Self.respondJSON(context: context, status: .conflict, error: msg)
                case .internalFailure(let msg):
                    Self.respondJSON(context: context, status: .internalServerError, error: msg)
                }
            }
            Task {
                promise.succeed(await creator(decoded))
            }
        }

        /// Encode a concrete array and respond 200 (or 500 on encoding
        /// failure). Called from the `/sessions` and `/repos` handlers
        /// once they've resolved their respective providers — kept
        /// non-generic so there's no runtime-generic dispatch on NIO's
        /// event loop, which surfaced as an unreachable-test hang on
        /// CI when the first call site was generic.
        private static func respondEncodable<T: Encodable>(
            context: ChannelHandlerContext,
            items: [T]
        ) {
            do {
                let data = try JSONEncoder().encode(items)
                Self.respond(
                    context: context,
                    status: .ok,
                    body: data,
                    contentType: "application/json; charset=utf-8"
                )
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .internalServerError,
                    error: "encoding error"
                )
            }
        }

        /// Respond with `{"error": "<msg>"}`. The client always gets
        /// JSON even for 4xx/5xx so it can render the error inline next
        /// to the form field without special-casing content type.
        static func respondJSON(
            context: ChannelHandlerContext,
            status: HTTPResponseStatus,
            error: String
        ) {
            struct ErrorBody: Codable { let error: String }
            let body = (try? JSONEncoder().encode(ErrorBody(error: error)))
                ?? Data(#"{"error":"unknown"}"#.utf8)
            Self.respond(
                context: context,
                status: status,
                body: body,
                contentType: "application/json; charset=utf-8"
            )
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
