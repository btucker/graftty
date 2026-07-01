import Foundation
import NIO
import NIOHTTP1
import GrafttyProtocol

// MARK: - PairingHTTPServer

/// Ephemeral plaintext-HTTP listener that serves the two device-pairing
/// routes over the LAN, bridging NIO's event-loop world to the async
/// `HostPairingServer` actor.
///
/// @spec REMOTE-1.4: While no pairing session is active, the host shall
/// not accept connections on the pairing endpoint; the pairing listener
/// runs only for the lifetime of an active pairing session. The host UI
/// is responsible for calling `start()` when it shows a pairing QR code
/// and `stop()` once pairing completes, is cancelled, or expires.
///
/// No TLS, no auth, no static assets: the pairing protocol is
/// self-authenticating (nonce-scoped requests, then a public-key
/// exchange verified against the QR-pinned fingerprint), and the
/// listener's bounded lifetime is the access control.
public actor PairingHTTPServer {

    private let pairingServer: HostPairingServer
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var lifecycle: Lifecycle = .idle

    /// Actors only interleave at suspension points: `start()` and `stop()`
    /// both suspend mid-method (binding the socket / closing the channel
    /// and shutting down the event-loop group). A state check made purely
    /// from `group`/`channel` optionality — checked before that suspension
    /// but assigned only after it resumes — lets two concurrent callers
    /// both observe the pre-transition state and both proceed. `lifecycle`
    /// is claimed synchronously, before the first `await` in either
    /// method, so the second concurrent caller always observes the first
    /// caller's claim.
    private enum Lifecycle {
        case idle
        case starting
        case running
        case stopping
    }

    /// Thrown by `start()` when the server is already starting, running,
    /// or stopping. A second concurrent (or sequential) `start()` call
    /// fails deterministically rather than racing the first to bind a
    /// second, orphaned listener.
    public enum LifecycleError: Swift.Error, Equatable {
        case alreadyStarted
    }

    // MARK: Init

    public init(pairingServer: HostPairingServer) {
        self.pairingServer = pairingServer
    }

    // MARK: - Lifecycle

    /// Binds a plaintext HTTP/1.1 listener. Returns the bound port (pass
    /// port 0 for ephemeral). Serves ONLY `POST /v1/pairing/introduce`
    /// and `POST /v1/pairing/await-outcome`; every other request gets a
    /// 404 (unknown path) or 405 (wrong method on a pairing route).
    ///
    /// Throws `LifecycleError.alreadyStarted` if the server is already
    /// starting, running, or stopping.
    @discardableResult
    public func start(host: String = "0.0.0.0", port: Int = 0) async throws -> Int {
        guard lifecycle == .idle else {
            throw LifecycleError.alreadyStarted
        }
        lifecycle = .starting

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let pairingServer = self.pairingServer

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(pairingServer: pairingServer))
                }
            }

        do {
            let boundChannel = try await bootstrap.bind(host: host, port: port).get()
            self.group = group
            self.channel = boundChannel
            lifecycle = .running
            return boundChannel.localAddress?.port ?? port
        } catch {
            try? await Self.shutdown(group)
            lifecycle = .idle
            throw error
        }
    }

    /// Closes the listening channel and shuts down the owned event loop
    /// group. Idempotent — safe to call when never started, already
    /// stopped, or concurrently with another in-flight `stop()`: only the
    /// first caller to observe `.running`/`.starting` performs the
    /// teardown, every other concurrent or subsequent call is a no-op.
    public func stop() async {
        guard lifecycle == .running || lifecycle == .starting else {
            return
        }
        lifecycle = .stopping

        if let channel {
            try? await channel.close().get()
        }
        channel = nil
        if let group {
            try? await Self.shutdown(group)
        }
        group = nil
        lifecycle = .idle
    }

    private static func shutdown(_ group: MultiThreadedEventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - HTTPHandler

    /// Accumulates one request's body per NIO's `.head`/`.body`/`.end`
    /// parts, then routes it. `/await-outcome` may suspend inside the
    /// actor for minutes, so the handler never blocks the event loop:
    /// it bridges to a `Task` that awaits `HostPairingServer` and writes
    /// the response back via an `EventLoopPromise`, whose `succeed(_:)`
    /// hops onto the channel's event loop regardless of which thread
    /// calls it. Mirrors `WebServer.HTTPHandler.handleSignalingOffer`.
    private final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        /// Cap accumulated request body before giving up. Both pairing
        /// request bodies are small fixed-shape JSON (~200 bytes); this
        /// is a hard stop against a malicious loopback client streaming
        /// an endless body to pin server memory.
        private static let maxBodyBytes = 64 * 1024

        private let pairingServer: HostPairingServer
        private var currentRequestHead: HTTPRequestHead?
        private var currentRequestBody = Data()
        private var bodyTooLarge = false

        init(pairingServer: HostPairingServer) {
            self.pairingServer = pairingServer
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

                if wasTooLarge {
                    Self.respondPlainText(
                        context: context,
                        status: .payloadTooLarge,
                        message: "request body exceeds \(Self.maxBodyBytes) bytes"
                    )
                    return
                }
                route(context: context, head: head, body: body)
            }
        }

        private func route(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
            let path = head.uri.split(separator: "?").first.map(String.init) ?? "/"
            switch path {
            case "/v1/pairing/introduce":
                guard head.method == .POST else {
                    Self.respondPlainText(context: context, status: .methodNotAllowed, message: "only POST is supported")
                    return
                }
                handleIntroduce(context: context, body: body)
            case "/v1/pairing/await-outcome":
                guard head.method == .POST else {
                    Self.respondPlainText(context: context, status: .methodNotAllowed, message: "only POST is supported")
                    return
                }
                handleAwaitOutcome(context: context, body: body)
            default:
                Self.respondPlainText(context: context, status: .notFound, message: "not found")
            }
        }

        /// Decode the JSON body as `PairingIntroduceRequest`, dispatch to
        /// the actor, and map the `Result` to an HTTP status + JSON body.
        private func handleIntroduce(context: ChannelHandlerContext, body: Data) {
            let request: PairingIntroduceRequest
            do {
                request = try JSONDecoder.iso8601().decode(PairingIntroduceRequest.self, from: body)
            } catch {
                Self.respondError(
                    context: context,
                    status: .badRequest,
                    code: .internalError,
                    error: "malformed introduce request: \(error.localizedDescription)"
                )
                return
            }

            let pairingServer = self.pairingServer
            // `ChannelHandlerContext` isn't `Sendable`; `loopBound` proves to
            // the compiler what NIO's contract already guarantees — the
            // `whenComplete` callback below runs back on `context.eventLoop`
            // (the same loop this handler always runs on) because the
            // promise was created from it.
            let loopBoundContext = context.loopBound
            let promise = context.eventLoop.makePromise(of: Result<PairingIntroduceResponse, PairingErrorResponse>.self)
            promise.futureResult.whenComplete { result in
                Self.respondToOutcome(context: loopBoundContext.value, result: result)
            }
            Task {
                promise.succeed(await pairingServer.handleIntroduce(request))
            }
        }

        /// Decode the JSON body as `PairingAwaitOutcomeRequest` and long-
        /// poll the actor for the terminal outcome. The `Task` may take
        /// minutes to complete (host UI confirm/deny or session expiry);
        /// the event loop is free to serve other connections in the
        /// meantime since nothing here blocks it.
        private func handleAwaitOutcome(context: ChannelHandlerContext, body: Data) {
            let request: PairingAwaitOutcomeRequest
            do {
                request = try JSONDecoder.iso8601().decode(PairingAwaitOutcomeRequest.self, from: body)
            } catch {
                Self.respondError(
                    context: context,
                    status: .badRequest,
                    code: .internalError,
                    error: "malformed await-outcome request: \(error.localizedDescription)"
                )
                return
            }

            let pairingServer = self.pairingServer
            let loopBoundContext = context.loopBound
            let promise = context.eventLoop.makePromise(of: Result<PairingOutcomeResponse, PairingErrorResponse>.self)
            promise.futureResult.whenComplete { result in
                Self.respondToOutcome(context: loopBoundContext.value, result: result)
            }
            Task {
                promise.succeed(await pairingServer.handleAwaitOutcome(request))
            }
        }

        // MARK: - Response helpers

        private static func respondToOutcome<T: Encodable>(
            context: ChannelHandlerContext,
            result: Swift.Result<Result<T, PairingErrorResponse>, Error>
        ) {
            switch try? result.get() {
            case .success(let value):
                respondEncodable(context: context, status: .ok, value: value)
            case .failure(let error):
                respondError(context: context, status: .badRequest, code: error.code, error: error.error)
            case .none:
                respondError(context: context, status: .internalServerError, code: .internalError, error: "pairing dispatch failed")
            }
        }

        private static func respondEncodable(context: ChannelHandlerContext, status: HTTPResponseStatus, value: some Encodable) {
            do {
                let data = try JSONEncoder.iso8601().encode(value)
                respond(context: context, status: status, body: data, contentType: "application/json; charset=utf-8")
            } catch {
                respondError(context: context, status: .internalServerError, code: .internalError, error: "encoding error")
            }
        }

        private static func respondError(context: ChannelHandlerContext, status: HTTPResponseStatus, code: PairingErrorResponse.Code, error: String) {
            let body = (try? JSONEncoder.iso8601().encode(PairingErrorResponse(code: code, error: error)))
                ?? Data(#"{"error":"unknown","code":"internalError"}"#.utf8)
            respond(context: context, status: status, body: body, contentType: "application/json; charset=utf-8")
        }

        private static func respondPlainText(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
            respond(context: context, status: status, body: Data("\(message)\n".utf8), contentType: "text/plain; charset=utf-8")
        }

        private static func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, contentType: String) {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: "\(body.count)")
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: status, headers: headers)
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
            let loopBoundContext = context.loopBound
            let donePromise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: donePromise)
            donePromise.futureResult.whenComplete { _ in
                loopBoundContext.value.close(promise: nil)
            }
        }
    }
}
