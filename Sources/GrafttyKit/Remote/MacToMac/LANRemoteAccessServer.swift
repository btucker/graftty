import Foundation
import GrafttyProtocol
import NIO
import NIOHTTP1

/// Plain HTTP listener for Mac-to-Mac LAN pairing and signaling.
///
/// This intentionally stays separate from `WebServer`: no TLS, no static web
/// assets, no WebSocket/zmx handling. Trust is established later by the
/// pairing transcript and host acceptance flow.
///
/// `@unchecked Sendable` is used because NIO's `EventLoopGroup` and `Channel`
/// do not conform to `Sendable`; lifecycle state is lock-protected and request
/// handler state is confined to each channel's event loop.
public final class LANRemoteAccessServer: @unchecked Sendable {
    public struct Config: Sendable {
        public var port: Int
        public var bindHost: String
        public var maxBodyBytes: Int

        public init(
            port: Int = 0,
            bindHost: String = "0.0.0.0",
            maxBodyBytes: Int = 1_048_576
        ) {
            self.port = port
            self.bindHost = bindHost
            self.maxBodyBytes = max(0, maxBodyBytes)
        }
    }

    public let config: Config

    public var listeningPort: Int? {
        lock.withLock {
            state.listener?.localAddress?.port
        }
    }

    private let routeHandler: LANRemoteAccessRouteHandler
    private let lock = NSLock()
    private var state = LifecycleState()

    private struct LifecycleState {
        var group: EventLoopGroup?
        var listener: Channel?
        var childChannels: [ObjectIdentifier: Channel] = [:]
    }

    public init(config: Config = .init(), routeHandler: LANRemoteAccessRouteHandler) {
        self.config = config
        self.routeHandler = routeHandler
    }

    public func start() throws {
        lock.lock()
        precondition(
            state.group == nil && state.listener == nil,
            "LANRemoteAccessServer already started"
        )

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        state.group = group

        let routeHandler = self.routeHandler
        let maxBodyBytes = config.maxBodyBytes
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                registerChildChannel(channel)
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(
                        routeHandler: routeHandler,
                        maxBodyBytes: maxBodyBytes
                    ))
                }
            }

        do {
            state.listener = try bootstrap.bind(host: config.bindHost, port: config.port).wait()
            lock.unlock()
        } catch {
            state.group = nil
            lock.unlock()
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    public func stop() {
        let snapshot = lock.withLock {
            let snapshot = state
            state = LifecycleState()
            return snapshot
        }

        try? snapshot.listener?.close().wait()
        for child in snapshot.childChannels.values {
            try? child.close().wait()
        }
        try? snapshot.group?.syncShutdownGracefully()
    }

    private func registerChildChannel(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        lock.withLock {
            state.childChannels[id] = channel
        }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.unregisterChildChannel(id)
        }
    }

    private func unregisterChildChannel(_ id: ObjectIdentifier) {
        lock.withLock {
            state.childChannels[id] = nil
        }
    }

    // @unchecked Sendable: NIO invokes inbound callbacks for a channel on its
    // event loop, so the per-request accumulation state is event-loop confined.
    private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let routeHandler: LANRemoteAccessRouteHandler
        private let maxBodyBytes: Int
        private var currentRequestHead: HTTPRequestHead?
        private var currentRequestBody = Data()
        private var acceptingRequest = true
        private var responseStarted = false
        private var routeTask: Task<Void, Never>?

        init(routeHandler: LANRemoteAccessRouteHandler, maxBodyBytes: Int) {
            self.routeHandler = routeHandler
            self.maxBodyBytes = maxBodyBytes
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                guard acceptingRequest && !responseStarted else { return }
                currentRequestHead = head
                currentRequestBody.removeAll(keepingCapacity: true)

            case .body(var buffer):
                guard acceptingRequest && !responseStarted else { return }
                let readableBytes = buffer.readableBytes
                guard currentRequestBody.count + readableBytes <= maxBodyBytes else {
                    acceptingRequest = false
                    responseStarted = true
                    currentRequestBody.removeAll(keepingCapacity: false)
                    currentRequestHead = nil
                    Self.respond(
                        context: context,
                        response: Self.bodyTooLargeResponse(maxBodyBytes: maxBodyBytes)
                    )
                    return
                }
                if let bytes = buffer.readBytes(length: readableBytes) {
                    currentRequestBody.append(contentsOf: bytes)
                }

            case .end:
                guard acceptingRequest && !responseStarted, let head = currentRequestHead else { return }
                acceptingRequest = false
                responseStarted = true
                currentRequestHead = nil
                let body = currentRequestBody
                currentRequestBody = Data()

                guard let method = LANRemoteAccessMethod(httpMethod: head.method) else {
                    Self.respond(context: context, response: Self.methodNotAllowedResponse())
                    return
                }

                let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
                let routeHandler = self.routeHandler
                let promise = context.eventLoop.makePromise(of: LANRemoteAccessResponse.self)
                promise.futureResult.whenComplete { result in
                    guard context.channel.isActive else { return }
                    switch result {
                    case .success(let response):
                        Self.respond(context: context, response: response)
                    case .failure(let error):
                        Self.respond(context: context, response: Self.internalErrorResponse(error))
                    }
                }
                routeTask = Task {
                    let response = await routeHandler.handle(method: method, path: path, body: body)
                    guard !Task.isCancelled else { return }
                    promise.succeed(response)
                }
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            routeTask?.cancel()
            routeTask = nil
        }

        private static func respond(context: ChannelHandlerContext, response: LANRemoteAccessResponse) {
            guard context.channel.isActive else { return }

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: response.contentType)
            headers.add(name: "Content-Length", value: "\(response.body.count)")
            headers.add(name: "Connection", value: "close")

            let status = HTTPResponseStatus(statusCode: response.status)
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)

            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

            let donePromise = context.eventLoop.makePromise(of: Void.self)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: donePromise)
            donePromise.futureResult.whenComplete { _ in
                context.close(promise: nil)
            }
        }

        private static func bodyTooLargeResponse(maxBodyBytes: Int) -> LANRemoteAccessResponse {
            errorResponse(
                status: 413,
                code: .internalError,
                message: "request body exceeds \(maxBodyBytes) bytes"
            )
        }

        private static func methodNotAllowedResponse() -> LANRemoteAccessResponse {
            errorResponse(
                status: 405,
                code: .wrongSessionState,
                message: "method not allowed"
            )
        }

        private static func internalErrorResponse(_ error: Error) -> LANRemoteAccessResponse {
            errorResponse(
                status: 500,
                code: .internalError,
                message: "request failed: \(error.localizedDescription)"
            )
        }

        private static func errorResponse(
            status: Int,
            code: PairingErrorResponse.Code,
            message: String
        ) -> LANRemoteAccessResponse {
            let error = PairingErrorResponse(code: code, error: message)
            let body = (try? JSONEncoder.iso8601().encode(error))
                ?? Data(#"{"code":"internalError","error":"encoding error"}"#.utf8)
            return LANRemoteAccessResponse(
                status: status,
                body: body,
                contentType: "application/json; charset=utf-8"
            )
        }
    }
}

private extension LANRemoteAccessMethod {
    init?(httpMethod: HTTPMethod) {
        switch httpMethod {
        case .GET:
            self = .GET
        case .POST:
            self = .POST
        default:
            return nil
        }
    }
}
