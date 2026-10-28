import Foundation
import GrafttyProtocol
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Client-side endpoint for the `panes-state@graftty.dev` SSH channel.
///
/// A push-only `SubsystemChannel`: the host streams `PanesStateMessage`
/// frames, which this client decodes and hands to the supplied callback.
public final class PanesStateChannelClient: @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case openFailed(any Error)
        case channelClosed
        case subsystemRejected
        case timedOut
    }

    public typealias OnSnapshot = @Sendable ([WorktreePanes]) async -> Void
    public typealias OnClosed = @Sendable (String) async -> Void

    private let channel: SubsystemChannel

    private let lock = NIOLock()
    /// Callbacks are mutable so the construction site can build the
    /// client with placeholders, hand it to its owning store, then
    /// backfill the closures pointing at the store. Production wiring
    /// (`buildPaneEnvironment`) uses that flow to break the
    /// store↔driver chicken-and-egg without a placeholder driver swap.
    private var navigationSnapshot: SidebarSnapshot?
    public var sidebarSnapshot: SidebarSnapshot? { lock.withLock { navigationSnapshot } }
    private var onSnapshot: OnSnapshot
    private var onClosed: OnClosed
    private var didNotifyClosed = false
    private let onSidebarSnapshot: @Sendable (SidebarSnapshot?) async -> Void

    /// Serial inbound queue. The frame relay yields raw frame bytes onto
    /// this stream; a single drain Task spawned in `open()` consumes them
    /// in order and dispatches to `onSnapshot`. A per-frame `Task { ... }`
    /// would NOT preserve wire order — Tasks awaiting an actor enqueue
    /// when their body awaits, not when they're spawned, so two snapshots
    /// arriving back-to-back could be applied to `WorktreePanesStore`
    /// out of order, leaving stale state.
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let inboundStream: AsyncStream<Data>

    public init(
        parentChannel: Channel,
        parentHandler: NIOSSHHandler,
        subsystemName: String = SSHChannelTypeNames.panesState,
        requestReply: Bool = false,
        subsystemReplyTimeout: TimeAmount = .seconds(30),
        childOpenTimeout: Duration = .seconds(10),
        onSnapshot: @escaping OnSnapshot,
        onClosed: @escaping OnClosed,
        onSidebarSnapshot: @escaping @Sendable (SidebarSnapshot?) async -> Void = { _ in }
    ) {
        // `PanesStateSubscription` sets `requestReply` so a peer that
        // predates panes-state-v2 can reject it and the caller can retry V1.
        self.channel = SubsystemChannel(
            parentChannel: parentChannel,
            parentHandler: parentHandler,
            subsystem: subsystemName,
            childOpenTimeout: childOpenTimeout,
            closeParentOnOpenTimeout: false,
            reply: requestReply
                ? .acknowledged(timeout: .nanoseconds(subsystemReplyTimeout.nanoseconds))
                : .written(wantReply: false),
            errors: SubsystemErrors(
                closed: ClientError.channelClosed,
                rejected: ClientError.subsystemRejected,
                timedOut: ClientError.timedOut
            )
        )
        self.onSnapshot = onSnapshot
        self.onClosed = onClosed
        self.onSidebarSnapshot = onSidebarSnapshot
        var cont: AsyncStream<Data>.Continuation!
        self.inboundStream = AsyncStream { c in cont = c }
        self.inboundContinuation = cont
    }

    /// Overwrites the snapshot + close callbacks installed at init.
    /// Lets `buildPaneEnvironment` construct the client first, hand it
    /// to its `WorktreePanesStore`, then point the callbacks at the
    /// store — avoiding the chicken-and-egg "store needs the client at
    /// init, client needs the store in its callbacks" cycle.
    public func setCallbacks(
        onSnapshot: @escaping OnSnapshot,
        onClosed: @escaping OnClosed
    ) {
        lock.withLock {
            self.onSnapshot = onSnapshot
            self.onClosed = onClosed
        }
    }

    /// Opens the SSH child channel. When `requestReply` is true, resolves
    /// only after the peer accepts the subsystem; otherwise resolves once
    /// the fire-and-forget request has been written.
    public func open() async throws {
        do {
            // The close callback is registered as soon as the child opens,
            // so a partial-open failure still propagates `onClosed` to the
            // store; otherwise its `connectionState` would stay
            // `.subscribed` indefinitely.
            // The close callback and the drain hold the client strongly, so
            // an owner that releases it still gets every snapshot and the
            // close. Both end with the channel: NIO drops the close callback
            // once it has run, and the drain ends when the stream finishes.
            try await channel.open(
                onFrame: { [inboundContinuation] in inboundContinuation.yield($0) },
                onError: { [weak self] _ in self?.failFeed() },
                onClose: { [self] in handleChildClose() }
            )
        } catch {
            // The inbound stream stays untouched: a rejected repeat open must
            // not end delivery for the channel that is already open, and a
            // failed first open never starts the drain that would read it.
            throw ClientError.openFailed(error)
        }
        // The single serial drain dispatches snapshots in wire order; frames
        // that arrived during the open wait in `inboundStream`.
        Task { [inboundStream, self] in
            for await bytes in inboundStream {
                // Snapshot the closure under the lock so a concurrent
                // setCallbacks(...) doesn't race with the read.
                let onSnapshot = self.lock.withLock { self.onSnapshot }
                guard
                    let message = try? JSONDecoder.shared.decode(PanesStateMessage.self, from: bytes)
                else {
                    // A stream that cannot be decoded is unhealthy even if
                    // its SSH parent still carries other working channels.
                    self.failFeed()
                    return
                }
                switch message {
                case .snapshot(let worktrees, let sidebar):
                    self.lock.withLock { self.navigationSnapshot = sidebar }
                    await self.onSidebarSnapshot(sidebar)
                    await onSnapshot(worktrees)
                }
            }
        }
    }

    /// Closes the SSH child channel.
    public func close() {
        inboundContinuation.finish()
        channel.close()
    }

    /// Protocol failure ends this feed immediately. The peer may never
    /// acknowledge SSH channel close, so owner notification cannot wait
    /// for the transport's close future.
    private func failFeed() {
        close()
        handleChildClose()
    }

    private func handleChildClose() {
        let onClosed: OnClosed? = lock.withLock {
            guard !didNotifyClosed else { return nil }
            didNotifyClosed = true
            return self.onClosed
        }
        guard let onClosed else { return }
        // Finish the inbound stream so the drain task exits cleanly.
        inboundContinuation.finish()
        Task { await onClosed("channel-closed") }
    }
}
