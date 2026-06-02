import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOSSH

/// Server-side channel-open dispatcher. Installs into every inbound
/// `.session` child channel and routes it to either R4's
/// `TerminalSessionHandler` or one of R5's custom-subsystem handlers
/// based on the first `SSHChannelRequestEvent` that arrives.
///
/// Why this exists: swift-nio-ssh 0.13's `SSHChannelType` enum has no
/// custom-channel-type case. Custom channel purposes (panes-state,
/// pane-control) ride on `.session` channels and are distinguished by
/// the SSH-level `subsystem` channel-request per RFC 4254 §6.5 —
/// exactly how SFTP works.
///
/// On the first observed request event:
///   - `env` / `pty-req` / `shell`  → R4 terminal-session path: install
///     `TerminalSessionHandler` and forward the observed event so the
///     handler can process it normally.
///   - `subsystem "panes-state@graftty.dev"` → install
///     `LengthPrefixedFraming` + `PanesStateChannelHandler` and ack.
///   - `subsystem "pane-control@graftty.dev"` → install
///     `LengthPrefixedFraming` + `PaneControlChannelHandler` and ack.
///   - Unknown subsystem → fail (if `wantReply`) and close the channel.
///
/// After dispatch the dispatcher removes itself from the pipeline.
public final class SubsystemDispatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private let panesStateSubscribe: PanesStateChannelHandler.Subscribe
    private let paneControlMutator: PaneControlChannelHandler.Mutator
    private var dispatched = false

    public init(
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        panesStateSubscribe: @escaping PanesStateChannelHandler.Subscribe,
        paneControlMutator: @escaping PaneControlChannelHandler.Mutator
    ) {
        self.streamFactory = streamFactory
        self.panesStateSubscribe = panesStateSubscribe
        self.paneControlMutator = paneControlMutator
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard !dispatched else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch event {
        case let subsystem as SSHChannelRequestEvent.SubsystemRequest:
            handleSubsystem(subsystem, context: context)
            return

        case is SSHChannelRequestEvent.EnvironmentRequest,
             is SSHChannelRequestEvent.PseudoTerminalRequest,
             is SSHChannelRequestEvent.ShellRequest:
            // Terminal session — R4's path. Install TerminalSessionHandler
            // after self, refire the event so the new handler can process
            // it (dispatched=true blocks recursion through self), then
            // remove self. Refire-before-remove keeps the event delivery
            // path simple: a mid-removal context behaves unevenly for
            // event firing in some NIO versions; doing it before
            // `removeHandler` avoids that whole class of subtlety.
            dispatched = true
            do {
                try context.pipeline.syncOperations.addHandler(
                    TerminalSessionHandler(streamFactory: streamFactory),
                    position: .after(self)
                )
                context.fireUserInboundEventTriggered(event)
                context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            } catch {
                context.close(promise: nil)
            }
            return

        default:
            // Unrelated user event — forward through; do not dispatch yet.
            context.fireUserInboundEventTriggered(event)
            return
        }
    }

    private func handleSubsystem(
        _ request: SSHChannelRequestEvent.SubsystemRequest,
        context: ChannelHandlerContext
    ) {
        switch request.subsystem {
        case SSHChannelTypeNames.panesState:
            dispatched = true
            installSubsystem(
                // Reverse-order install: pipeline at dispatch time is [self];
                // each `.after(self)` insert lands immediately after self,
                // pushing earlier inserts further down. Calling in reverse
                // order yields [self, codec, decoder, prepender, panesHandler].
                handler: PanesStateChannelHandler(subscribe: panesStateSubscribe),
                request: request,
                context: context
            )

        case SSHChannelTypeNames.paneControl:
            dispatched = true
            installSubsystem(
                handler: PaneControlChannelHandler(mutator: paneControlMutator),
                request: request,
                context: context
            )

        default:
            // Unknown subsystem — refuse cleanly.
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
            context.close(promise: nil)
        }
    }

    /// Installs the shared framing stack (codec → decoder → prepender → `handler`)
    /// after `self` in the pipeline, acks or nacks the subsystem request, then
    /// removes `self`. The reverse-insertion order ensures the pipeline reads as
    /// `[codec, decoder, prepender, handler]` from the channel inward.
    private func installSubsystem(
        handler: any NIOCore.ChannelHandler,
        request: SSHChannelRequestEvent.SubsystemRequest,
        context: ChannelHandlerContext
    ) {
        do {
            try context.pipeline.syncOperations.addHandler(handler, position: .after(self))
            try context.pipeline.syncOperations.addHandler(
                LengthPrefixedFraming.makeFramePrepender(), position: .after(self))
            try context.pipeline.syncOperations.addHandler(
                LengthPrefixedFraming.makeFrameDecoder(), position: .after(self))
            // SSHChannelDataCodec bridges SSHChannelData ↔ ByteBuffer
            // so the downstream framing handlers operate on raw bytes.
            try context.pipeline.syncOperations.addHandler(
                SSHChannelDataCodec(), position: .after(self))
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        } catch {
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
            context.close(promise: nil)
        }
    }
}
