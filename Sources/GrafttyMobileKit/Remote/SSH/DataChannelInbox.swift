#if canImport(UIKit)
import Foundation
import WebRTC

/// Lossless inbound tap for an `RTCDataChannel`.
///
/// An RTCDataChannel only delivers messages to whatever delegate is
/// attached at delivery time — bytes that arrive while the wrong (or a
/// no-op) delegate is installed are gone forever. For SSH-over-
/// DataChannel that is fatal: the peer writes its SSH version banner
/// the instant its own open notification lands, which can precede this
/// side's `SSHNIOTransport` construction by several scheduler hops, and
/// a lost banner deadlocks the handshake with both sides waiting
/// (the IPAD-5.2 CI flake's dominant cause).
///
/// Attach an inbox as the channel's delegate as early as possible —
/// for a received channel, synchronously inside
/// `peerConnection(_:didOpen:)` on WebRTC's delegate thread (message
/// delivery is serialized behind that callback, so a delegate attached
/// before it returns can never miss a byte); for a locally-created
/// channel, immediately after creation. The inbox stays the channel's
/// delegate forever. It buffers every message and state transition
/// under a lock until a consumer attaches via `attach(...)`, then
/// replays the backlog and forwards everything subsequent, all under
/// the same lock so no delivery can reorder around the handoff.
///
/// Consumer closures are invoked while the lock is held and therefore
/// MUST be non-blocking and must not call back into the inbox —
/// `SSHNIOTransport` satisfies this by only enqueueing onto its event
/// loop.
public final class DataChannelInbox: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    /// Mirror of `SSHNIOTransport.pendingInboundByteCap`: if the peer
    /// floods before a consumer attaches, poison the inbox (drop the
    /// buffer, surface as a close) rather than grow unbounded.
    private static let bufferedByteCap: Int = 1 * 1024 * 1024

    private let lock = NSLock()
    private var bufferedMessages: [Data] = []
    private var bufferedByteCount = 0
    private var openObserved = false
    private var closedObserved = false
    private var onOpen: (@Sendable () -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var onMessage: (@Sendable (Data) -> Void)?

    /// Install the consumer and replay the backlog in arrival order:
    /// open transition first, then every buffered message, then a close
    /// transition if one was observed. Runs entirely under the inbox
    /// lock; concurrent WebRTC deliveries serialize behind it, so the
    /// consumer sees one totally-ordered stream.
    func attach(
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable () -> Void,
        onMessage: @escaping @Sendable (Data) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.onOpen = onOpen
        self.onClose = onClose
        self.onMessage = onMessage
        if openObserved { onOpen() }
        for message in bufferedMessages { onMessage(message) }
        bufferedMessages = []
        bufferedByteCount = 0
        if closedObserved { onClose() }
    }

    // MARK: - RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            observeOpen()
        case .closing, .closed:
            observeClosed()
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        receive(buffer.data)
    }

    // MARK: - Ingestion (internal so unit tests can drive the inbox
    // without fabricating RTCDataChannel/RTCDataBuffer instances)

    func observeOpen() {
        lock.lock()
        defer { lock.unlock() }
        if let onOpen {
            onOpen()
        } else {
            openObserved = true
        }
    }

    func observeClosed() {
        lock.lock()
        defer { lock.unlock() }
        if let onClose {
            onClose()
        } else {
            closedObserved = true
        }
    }

    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closedObserved else { return }
        if let onMessage {
            onMessage(data)
            return
        }
        bufferedByteCount += data.count
        guard bufferedByteCount <= Self.bufferedByteCap else {
            // Flood before any consumer: poison rather than grow
            // unbounded. Surfaces to the eventual consumer as a close.
            bufferedMessages = []
            closedObserved = true
            return
        }
        bufferedMessages.append(data)
    }
}
#endif
