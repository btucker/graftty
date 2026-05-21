#if canImport(UIKit)
import Foundation
import NIO
import NIOEmbedded
import WebRTC

/// Adapter that bridges WebRTC's `RTCDataChannel` (a message-stream API)
/// to a swift-nio `Channel` (a byte-stream API) so that handlers like
/// `NIOSSHHandler` can run over an SCTP-backed DataChannel.
///
/// Mirror of `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`. The
/// two files are kept as near-duplicates per the codebase precedent
/// (`ChannelRouter` on Mac/mobile) so the Mac-side host agent and the
/// iOS mobile client speak the same byte-stream-over-DataChannel
/// shape without a shared module.
///
/// Architecture:
/// - The transport owns a `NIOAsyncTestingChannel` running on a fresh
///   `NIOAsyncTestingEventLoop`. Consumers install their own handlers
///   (e.g. `NIOSSHHandler`) onto `transport.channel.pipeline`.
/// - `NIOAsyncTestingEventLoop` is used (rather than `EmbeddedEventLoop`)
///   because its `execute(_:)` from off-loop threads automatically
///   drains queued tasks via `queue.async { ... _run() }`. The bare
///   `EmbeddedEventLoop` only queues — its tasks never run without an
///   explicit `run()` pump, which would hang `start()`, `close()`, and
///   inbound delivery. R4 may revisit this if production wiring reveals
///   a problem with the testing primitive in non-test code paths.
/// - An internal `OutboundRelayHandler` sits at the head of the pipeline
///   and forwards every outbound `ByteBuffer` write to
///   `RTCDataChannel.sendData(_:)`. ByteBuffers larger than `mtu` are
///   split into multiple SCTP messages — SSH is byte-stream oriented,
///   so the boundary split is transparent to `NIOSSHHandler` on the
///   receiving side.
/// - `RTCDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)`
///   fires on WebRTC's serial dispatch queue. The transport hops onto
///   the testing loop via `eventLoop.execute { ... }` and calls
///   `writeInbound(_:)`, which fires `channelRead` through the pipeline.
/// - `start()` blocks until the DataChannel reaches `.open`, then fires
///   `channelActive` (via `NIOAsyncTestingChannel.connect`). The SSH
///   handler's handshake runs from `channelActive`.
///
/// The transport does not install `NIOSSHHandler` itself — that's the
/// consumer's responsibility (loopback test in R2, production callers
/// in R4). The transport just provides the byte-stream `Channel`.
///
/// Concurrency: `@unchecked Sendable` because the transport carries its
/// own synchronization — all NIO state lives on the testing loop, and
/// all WebRTC delegate callbacks are bridged onto that loop via
/// `execute`. The delegate (`DataChannelDelegate`) is itself
/// `@unchecked Sendable` with the WebRTC SDK serial-queue invariant
/// documented in `RemoteHostConnection`.
public final class SSHNIOTransport: @unchecked Sendable {

    /// Maximum bytes per outbound SCTP message. WebRTC defaults
    /// permit messages up to 256 KB, but ~16 KB matches the
    /// commonly-quoted "always-safe" SCTP fragmentation boundary
    /// across implementations. SSH framing is byte-stream oriented,
    /// so splitting a single NIO `ByteBuffer` write across multiple
    /// SCTP messages is transparent to `NIOSSHHandler`.
    public static let mtu: Int = 16 * 1024

    public enum TransportError: Error, Sendable {
        /// `start()` was called but the DataChannel transitioned to
        /// `.closing` / `.closed` before reaching `.open`.
        case dataChannelClosedBeforeOpen
        /// `start()` was called twice.
        case alreadyStarted
        /// The transport has been closed.
        case closed
    }

    /// The underlying NIO `Channel`. Consumers install their own
    /// `ChannelHandler`s (e.g. `NIOSSHHandler`) onto its pipeline.
    public var channel: Channel { embedded }

    /// Convenience accessor for the embedded event loop. Identical to
    /// `channel.eventLoop`.
    public var eventLoop: EventLoop { embeddedLoop }

    private let dataChannel: RTCDataChannel
    private let embeddedLoop: NIOAsyncTestingEventLoop
    private let embedded: NIOAsyncTestingChannel
    /// Strongly held — `RTCDataChannel.delegate` is `weak`. Without a
    /// strong reference here the delegate would deallocate the moment
    /// `init` returns and every inbound message would be dropped.
    private let dcDelegate: DataChannelDelegate

    /// One-shot continuation resumed when the DataChannel first reaches
    /// `.open`. Accessed only on `embeddedLoop` to keep the
    /// state-transition ordering single-threaded.
    private var startContinuation: CheckedContinuation<Void, Error>?
    /// Tracks whether `start()` was already called so a redundant call
    /// throws rather than installing a second continuation that would
    /// leak.
    private var startCalled: Bool = false
    /// Set once the channel has been closed so late `start()` callers
    /// fail fast rather than hang on a never-fired open callback.
    private var closed: Bool = false

    public init(dataChannel: RTCDataChannel) {
        self.dataChannel = dataChannel
        let loop = NIOAsyncTestingEventLoop()
        self.embeddedLoop = loop
        // Create the channel without handlers first; register it and
        // install the OutboundRelayHandler synchronously below using
        // `submit(...).wait()`. `NIOAsyncTestingEventLoop.execute`
        // self-pumps via `queue.async { _run() }`, so a synchronous
        // wait from off-loop completes once the queued task runs.
        let channel = NIOAsyncTestingChannel(loop: loop)
        self.embedded = channel
        // OutboundRelayHandler is added at init time so it ends up at
        // the head of the pipeline (closest to the channel core). Every
        // outbound `write` from a handler added later by the consumer
        // (e.g. `NIOSSHHandler`) flows through OutboundRelayHandler on
        // its way to the channel core, where the relay diverts it onto
        // the DataChannel rather than letting it accumulate in the
        // embedded core's pendingOutboundBuffer.
        let relay = OutboundRelayHandler(
            dataChannel: dataChannel,
            mtu: Self.mtu
        )
        // Add the relay and register the channel synchronously. The
        // loop auto-pumps on `execute` (which `submit` uses internally),
        // so `.wait()` returns once the registration task has run.
        // Failure here would mean NIO has a bug — both `addHandler` and
        // `register` on an unregistered channel are infallible in this
        // setup.
        try! loop.submit {
            try channel.pipeline.syncOperations.addHandler(relay)
            channel.register(promise: nil)
        }.wait()
        self.dcDelegate = DataChannelDelegate()
        dataChannel.delegate = dcDelegate

        // Install delegate callbacks before returning so a `.open`
        // transition that fires between `init` and the caller's
        // `start()` is observed: `start()` checks `readyState` once
        // synchronously on-loop, and otherwise parks a continuation
        // that `handleDataChannelOpen` will resume.
        dcDelegate.onOpen = { [weak self] in
            guard let self else { return }
            self.embeddedLoop.execute {
                self.handleDataChannelOpen()
            }
        }
        dcDelegate.onClose = { [weak self] in
            guard let self else { return }
            self.embeddedLoop.execute {
                self.handleDataChannelClosed()
            }
        }
        dcDelegate.onMessage = { [weak self] data in
            guard let self else { return }
            self.embeddedLoop.execute {
                self.deliverInbound(data)
            }
        }
    }

    /// Block until the DataChannel reaches `.open`, then fire
    /// `channelActive` through the pipeline.
    ///
    /// If the DataChannel is already open when `start()` is called,
    /// `channelActive` fires synchronously on the embedded event loop
    /// and the call returns. Calling `start()` more than once throws
    /// `TransportError.alreadyStarted`.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            embeddedLoop.execute {
                if self.closed {
                    continuation.resume(throwing: TransportError.closed)
                    return
                }
                if self.startCalled {
                    continuation.resume(throwing: TransportError.alreadyStarted)
                    return
                }
                self.startCalled = true

                let state = self.dataChannel.readyState
                switch state {
                case .open:
                    self.fireChannelActive()
                    continuation.resume()
                case .closing, .closed:
                    continuation.resume(throwing: TransportError.dataChannelClosedBeforeOpen)
                case .connecting:
                    self.startContinuation = continuation
                @unknown default:
                    // Future SDK-introduced pre-open states are treated
                    // like `.connecting` — park the continuation until
                    // `handleDataChannelOpen` / `handleDataChannelClosed`
                    // fires.
                    self.startContinuation = continuation
                }
            }
        }
    }

    /// Close the transport: closes the DataChannel and tears the
    /// embedded channel down. Idempotent.
    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            embeddedLoop.execute {
                self.performClose()
                continuation.resume()
            }
        }
    }

    // MARK: - Embedded-loop-isolated helpers

    private func fireChannelActive() {
        // `NIOAsyncTestingChannel.connect(to:)` marks the channel
        // active and fires `channelActive` through the pipeline. The
        // address is fake — there is no real socket. A unix-domain-
        // socket path of "graftty-ssh" gives `localAddress` /
        // `remoteAddress` something human-readable for diagnostic logs.
        //
        // `try!` is safe: unix-domain-socket paths are limited to 104
        // bytes on Darwin, and the literal "graftty-ssh" is 12 bytes.
        // Avoid a fallback path here — a `fireChannelActive()`
        // without `connect` would leave `remoteAddress` nil and
        // silently diverge from the `connect`-completed state shape.
        let address = try! SocketAddress(unixDomainSocketPath: "graftty-ssh")
        embedded.connect(to: address, promise: nil)
    }

    private func handleDataChannelOpen() {
        // Two gates: `closed` (set by `performClose`) prevents firing
        // channelActive on a torn-down pipeline; `startContinuation`
        // (set by `start()` when it parks on `.connecting`) ensures
        // we only fire when a caller is actively awaiting an open.
        // Without `startContinuation` we'd fire on every `.open`
        // delegate event, including spurious re-opens if the SDK ever
        // exposed one.
        guard !closed else { return }
        if let continuation = startContinuation {
            startContinuation = nil
            fireChannelActive()
            continuation.resume()
        }
    }

    private func handleDataChannelClosed() {
        guard !closed else { return }
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: TransportError.dataChannelClosedBeforeOpen)
        }
        performClose()
    }

    private func deliverInbound(_ data: Data) {
        guard !closed, embedded.isActive else { return }
        var buffer = embedded.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        // We're already on the testing loop (this is invoked from an
        // `embeddedLoop.execute` block). `NIOAsyncTestingChannel`'s
        // public `writeInbound` is async because it hops onto the loop
        // via `executeInContext`; here we bypass that and fire the
        // pipeline events directly, which is the same work the async
        // path performs under the hood. Errors that travel past the
        // tail are surfaced via the channel's stored error, which
        // production callers can drain by adding an `ErrorHandler`.
        embedded.pipeline.fireChannelRead(buffer)
        embedded.pipeline.fireChannelReadComplete()
    }

    private func performClose() {
        guard !closed else { return }
        closed = true
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: TransportError.closed)
        }
        // Detach delegate callbacks so any late WebRTC-thread events
        // become no-ops. Delegate itself stays alive (we own it) and
        // remains assigned to the DataChannel — the SDK clears it on
        // its own close path.
        dcDelegate.onOpen = nil
        dcDelegate.onClose = nil
        dcDelegate.onMessage = nil
        // Close the DataChannel first so any outbound writes still
        // pending in the embedded pipeline get rejected by the relay
        // handler's readyState check rather than queued onto a closed
        // channel.
        dataChannel.close()
        // We're already on the testing loop; call `close0` via the
        // channel's `close(mode:promise:)` path. This fires
        // `channelInactive` through the pipeline and tears down the
        // channel core. `NIOAsyncTestingChannel.finish()` is async and
        // does the same plus left-over-state inspection — we don't
        // need the latter, so call `close` directly to keep this
        // function synchronous.
        embedded.close(promise: nil)
    }
}

/// Pipeline-head outbound handler that diverts NIO `ByteBuffer` writes
/// onto the underlying `RTCDataChannel`. Sits between consumer handlers
/// and the embedded channel core; the embedded core never sees the
/// outbound bytes, so the core's pending-outbound buffer stays empty
/// and there is no manual pump to drain.
///
/// Buffers larger than `mtu` are split into multiple SCTP messages.
/// SSH framing is byte-stream oriented, so the receiver re-assembles
/// transparently — NIOSSHHandler doesn't care about SCTP message
/// boundaries.
private final class OutboundRelayHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let dataChannel: RTCDataChannel
    private let mtu: Int

    init(dataChannel: RTCDataChannel, mtu: Int) {
        self.dataChannel = dataChannel
        self.mtu = mtu
    }

    func write(
        context: ChannelHandlerContext,
        data: NIOAny,
        promise: EventLoopPromise<Void>?
    ) {
        let buffer = unwrapOutboundIn(data)
        let bytes = Data(buffer.readableBytesView)
        if bytes.isEmpty {
            promise?.succeed(())
            return
        }
        guard dataChannel.readyState == .open else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + mtu, bytes.count)
            let slice = bytes.subdata(in: offset..<end)
            let dcBuffer = RTCDataBuffer(data: slice, isBinary: true)
            // Backpressure note: `RTCDataChannel.bufferedAmount` is not
            // monitored here. R2's spike accepts this; R4+ should add
            // a bufferedAmountLowThreshold-driven write gate before
            // production use, otherwise a stalled receiver can OOM the
            // sender by ballooning the SCTP send buffer.
            if !dataChannel.sendData(dcBuffer) {
                // `sendData` returns false when the SCTP send buffer is
                // full or the channel transitioned to closing. Surface
                // it through the promise so the consumer's writeAndFlush
                // future fails rather than silently dropping bytes.
                promise?.fail(ChannelError.outputClosed)
                return
            }
            offset = end
        }
        promise?.succeed(())
    }

    // `flush` is a no-op: writes are sent synchronously above.
    func flush(context: ChannelHandlerContext) {
        // Intentionally no-op. SCTP send is synchronous from the API
        // boundary's perspective; the WebRTC SDK does its own
        // batching on top.
    }
}

/// `RTCDataChannelDelegate` shim. Identical pattern to
/// `RemoteHostConnection.DataChannelDelegate` — WebRTC dispatches
/// delegate calls on a fixed internal serial queue, so closure
/// mutation through `nonisolated(unsafe)` is safe under the SDK's
/// documented invariant.
private final class DataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onOpen: (@Sendable () -> Void)?
    nonisolated(unsafe) var onClose: (@Sendable () -> Void)?
    nonisolated(unsafe) var onMessage: (@Sendable (Data) -> Void)?

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            onOpen?()
        case .closing, .closed:
            onClose?()
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}
#endif
