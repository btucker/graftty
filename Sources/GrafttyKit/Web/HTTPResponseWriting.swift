import Foundation
import NIO
import NIOHTTP1

// MARK: - writeHTTPResponse

/// Writes a complete HTTP/1.1 response (head + body + end) on `context`
/// and closes the connection once the response has actually flushed.
///
/// Shared by `WebServer.HTTPHandler` and `PairingHTTPServer.HTTPHandler`
/// — both are one-shot, `Connection: close` responders with identical
/// head/body/end/close sequencing; this is the single implementation
/// both delegate to.
///
/// Chains `close` off the end-of-response flush promise rather than
/// closing synchronously after `writeAndFlush(..., promise: nil)`. NIO's
/// `close0(mode: .all)` cancels any writes still pending in
/// `PendingWritesManager` *after* closing the socket fd, so closing
/// synchronously after the flush truncates the body whenever the
/// kernel's TCP send buffer can't absorb the whole response in one pass
/// — which is the normal case on Tailscale's `utun` (MTU ~1280) and the
/// root cause of `ERR_CONTENT_LENGTH_MISMATCH` on `/app.js`.
///
/// `context.loopBound` proves to the compiler what NIO's contract
/// already guarantees: the `whenComplete` callback below runs back on
/// `context.eventLoop` — the same loop every caller of this function
/// runs on — because the promise was created from it. `ChannelHandlerContext`
/// itself isn't `Sendable`, so this is required for strict-concurrency
/// callers (`PairingHTTPServer`); it's a behavior-neutral no-op for
/// callers that don't need it (`WebServer`).
func writeHTTPResponse(
    context: ChannelHandlerContext,
    status: HTTPResponseStatus,
    body: Data,
    contentType: String
) {
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
