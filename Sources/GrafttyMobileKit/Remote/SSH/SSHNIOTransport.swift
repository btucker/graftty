#if canImport(UIKit)
import Foundation
import NIO
import NIOEmbedded
import WebRTC

/// Test seam: anything `OutboundRelayHandler` actually needs from
/// `RTCDataChannel`. Production wraps the concrete WebRTC type;
/// unit tests can substitute a stub that simulates `sendData`
/// returning false.
internal protocol DataChannelSink: AnyObject {
    var sinkReadyState: RTCDataChannelState { get }
    func sinkSend(_ buffer: RTCDataBuffer) -> Bool
    func sinkClose()
}

extension RTCDataChannel: DataChannelSink {
    var sinkReadyState: RTCDataChannelState { readyState }
    func sinkSend(_ buffer: RTCDataBuffer) -> Bool { sendData(buffer) }
    func sinkClose() { close() }
}

/// Adapter that bridges WebRTC's `RTCDataChannel` (a message-stream API)
/// to a swift-nio `Channel` (a byte-stream API) so that handlers like
/// `NIOSSHHandler` can run over an SCTP-backed DataChannel.
///
/// Mirror of `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`. The
/// two files are kept as near-duplicates so the Mac-side host agent and
/// the iOS mobile client speak the same byte-stream-over-DataChannel
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
    /// Inbound DataChannel messages that arrived AFTER the SDK callback
    /// fired but BEFORE the embedded channel became active via
    /// `fireChannelActive`. WebRTC dispatches `didReceiveMessageWith` on
    /// its own serial queue, so for an `RTCDataChannel` that is already
    /// `.open` when this transport is constructed, the first inbound
    /// message can race the embedded channel's `connect(to:)` — if
    /// `deliverInbound` runs before `fireChannelActive`, `isActive` is
    /// still false and the bytes would be silently lost. We buffer them
    /// here and replay on `fireChannelActive`.
    private var pendingInbound: [Data] = []

    /// Hard cap on `pendingInbound` total bytes. If the peer sends bytes
    /// faster than `start()` is called, we close the transport rather
    /// than grow memory unbounded. 1 MiB is well above the worst-case
    /// SSH banner+KEX+userauth handshake (~5–10 KB) and large enough
    /// that legitimate slow-start scenarios don't trip it.
    private static let pendingInboundByteCap: Int = 1 * 1024 * 1024
    private var pendingInboundByteCount: Int = 0

    /// Fires exactly once, the moment the transport becomes closed —
    /// whether via an explicit `close()` call or because the underlying
    /// DataChannel closed out from under it (remote hang-up, transport
    /// reset). `init` re-assigns `RTCDataChannel.delegate` to this
    /// transport's own `dcDelegate`, which means whatever delegate the
    /// caller had installed on the DataChannel before wrapping it here
    /// (e.g. `RemoteHostConnection`'s own `dataChannelDidChangeState`
    /// hook) stops receiving callbacks the instant this transport takes
    /// over. `onClose` is that caller's only remaining way to observe a
    /// DataChannel death once the transport owns it. Set via the
    /// initializer — see its doc comment.
    public var onClose: (@Sendable () -> Void)?

    /// `onClose` is an initializer parameter (rather than requiring the
    /// caller to set the `onClose` property after construction) so there
    /// is no window between `init` returning and the caller wiring up
    /// the callback — `init` re-assigns `dataChannel.delegate` to
    /// `dcDelegate` before returning, so a close landing in a
    /// post-construction gap would otherwise be observed by nothing.
    public init(dataChannel: RTCDataChannel, onClose: (@Sendable () -> Void)? = nil) {
        self.dataChannel = dataChannel
        self.onClose = onClose
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
            sink: dataChannel,
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

        // Wire every callback BEFORE handing `dcDelegate` to the
        // DataChannel as its delegate. WebRTC can dispatch a state change
        // the instant `dataChannel.delegate` is assigned (e.g. the
        // channel is already `.open`/`.closed` on a background queue) —
        // assigning the delegate first left a window where such a
        // transition would land on `dcDelegate.onOpen`/`onClose`/`onMessage`
        // while they were still nil, silently dropping it (a missed
        // terminal fire). Installing the closures first closes that
        // window: by the time the delegate is attached, every callback is
        // already live.
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

        dataChannel.delegate = dcDelegate
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

                switch self.dataChannel.readyState {
                case .open:
                    self.fireChannelActive()
                    continuation.resume()
                case .closing, .closed:
                    // Tear down (and fire `onClose`) BEFORE resuming so
                    // `onClose`'s "fires exactly once, whichever way the
                    // transport dies" contract holds even for a
                    // DataChannel that was already dead before `start()`
                    // was ever called — without this, a caller relying
                    // solely on `onClose` (rather than also catching
                    // `start()`'s thrown error) would never learn the
                    // transport never came up.
                    self.performClose()
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
        // Drain any inbound messages that arrived while the embedded
        // channel was still inactive. See `pendingInbound` for the
        // race this prevents.
        flushPendingInbound()
    }

    private func flushPendingInbound() {
        guard !pendingInbound.isEmpty, embedded.isActive else { return }
        for data in pendingInbound {
            var buffer = embedded.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            embedded.pipeline.fireChannelRead(buffer)
        }
        embedded.pipeline.fireChannelReadComplete()
        pendingInbound.removeAll()
        pendingInboundByteCount = 0
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
        guard !closed else { return }
        // Inbound bytes may arrive (via WebRTC's serial queue) before
        // the consumer has called `start()` and the embedded channel
        // has transitioned to active. Buffer them rather than dropping —
        // `fireChannelActive` replays the buffer once the pipeline is
        // ready. Without this, the SSH-over-WebRTC handshake hangs
        // intermittently on CI: the server emits its banner the instant
        // its transport starts, and on a fast peer that banner can
        // reach the client's `deliverInbound` before
        // `clientTransport.start()` has connected the embedded channel.
        if !embedded.isActive {
            pendingInboundByteCount += data.count
            if pendingInboundByteCount > Self.pendingInboundByteCap {
                // Bound memory: a peer flooding us before start() shall
                // not OOM the host. Close the transport so the consumer
                // sees a clean tear-down rather than silent memory growth.
                pendingInbound.removeAll()
                pendingInboundByteCount = 0
                performClose()
                return
            }
            pendingInbound.append(data)
            return
        }
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
        // Anything we never got around to delivering is dropped at
        // close — the consumer is tearing down so the bytes have
        // nowhere to go.
        pendingInbound.removeAll()
        pendingInboundByteCount = 0
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
        onClose?()
    }

    /// Internal test seam: forces an inbound delivery as if WebRTC's
    /// delegate had fired. Used by `SSHNIOTransportUnitTests` to
    /// exercise the buffering cap without standing up a real
    /// `RTCDataChannel` exchange.
    internal func deliverInboundForTesting(_ data: Data) {
        embeddedLoop.execute {
            self.deliverInbound(data)
        }
    }

    /// Internal test seam: returns the current byte-count of buffered
    /// inbound data. For verifying the cap behavior.
    internal var pendingInboundByteCountForTesting: Int {
        pendingInboundByteCount
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
internal final class OutboundRelayHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let sink: DataChannelSink
    private let mtu: Int

    init(sink: DataChannelSink, mtu: Int) {
        self.sink = sink
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
        guard sink.sinkReadyState == .open else {
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
            if !sink.sinkSend(dcBuffer) {
                // Partial-write: earlier slices have already shipped. We
                // cannot safely send any more bytes via this DataChannel
                // because the peer is mid-frame for an SSH packet and
                // ANY further write would corrupt the stream. Close
                // both ends so NIOSSHHandler tears down cleanly rather
                // than parsing garbage.
                promise?.fail(ChannelError.outputClosed)
                sink.sinkClose()
                context.close(mode: .all, promise: nil)
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
