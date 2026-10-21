import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyTunnel
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
///   - a subsystem in `framedSubsystems` (panes-state, pane-control,
///     worktree-management, Chrome tabs, team) → install
///     `LengthPrefixedFraming` with that subsystem's frame bound + its
///     handler and ack, or refuse when its factory declines the connection.
///   - Unknown subsystem → fail (if `wantReply`) and close the channel.
///
/// After dispatch the dispatcher removes itself from the pipeline.
public final class SubsystemDispatcher: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private let pagedFactory: PagedTerminalStreamFactory?
    private let panesStateSubscribe: PanesStateChannelHandler.Subscribe
    private let panesStateV2Subscribe: PanesStateChannelHandler.Subscribe
    private let chromeTabMutator: ChromeTabChannelHandler.Mutator?
    private let chromeTabOnDisconnect: ChromeTabChannelHandler.OnDisconnect
    private let paneControlMutator: PaneControlChannelHandler.Mutator
    private let worktreeManagementMutator: WorktreeManagementChannelHandler.Mutator
    /// REMOTE-9: display-ownership plumbing threaded through to
    /// `TerminalSessionHandler` for the terminal-session path only —
    /// panes-state/pane-control subsystem channels don't participate in
    /// display ownership.
    private let ownershipStore: SessionDisplayOwnershipStore
    private let ownershipBroadcaster: DisplayOwnershipBroadcaster
    /// Resolves the authenticated peer's device identity. A closure
    /// (rather than a plain value) because `SubsystemDispatcher` is
    /// constructed inside `WebRTCHostAgent`'s `inboundChildChannelInitializer`
    /// closure, which fires once per child channel — reading through a
    /// shared box at that point always sees the value userauth set before
    /// NIOSSH allowed any channel to open.
    private let deviceIDProvider: @Sendable () -> RemoteDeviceID?
    private let worktreeManagementAllowed: @Sendable () -> Bool
    /// Authenticated transport kind. The control envelope's kind remains
    /// caller-controlled and must not decide ownership eligibility.
    private let displayKindProvider: @Sendable () -> DisplayClientKind
    private let teamHandler: TeamChannelHandler.Handler?
    private let teamOnConnect: TeamChannelHandler.OnConnect
    private let teamOnDisconnect: TeamChannelHandler.OnDisconnect
    private let teamAllowed: @Sendable () -> Bool
    private let bulkChannels: BulkTerminalChannels?
    private let isBulkTransport: Bool
    private var dispatched = false

    public init(
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        pagedFactory: PagedTerminalStreamFactory? = nil,
        panesStateSubscribe: @escaping PanesStateChannelHandler.Subscribe,
        panesStateV2Subscribe: PanesStateChannelHandler.Subscribe? = nil,
        paneControlMutator: @escaping PaneControlChannelHandler.Mutator,
        worktreeManagementMutator: WorktreeManagementChannelHandler.Mutator? = nil,
        chromeTabMutator: ChromeTabChannelHandler.Mutator? = nil,
        chromeTabOnDisconnect: @escaping ChromeTabChannelHandler.OnDisconnect = { _ in },
        ownershipStore: SessionDisplayOwnershipStore,
        ownershipBroadcaster: DisplayOwnershipBroadcaster,
        deviceIDProvider: @escaping @Sendable () -> RemoteDeviceID?,
        worktreeManagementAllowed: @escaping @Sendable () -> Bool = { true },
        displayKindProvider: @escaping @Sendable () -> DisplayClientKind = { .ios },
        teamHandler: TeamChannelHandler.Handler? = nil,
        teamOnConnect: @escaping TeamChannelHandler.OnConnect = { _, _ in },
        teamOnDisconnect: @escaping TeamChannelHandler.OnDisconnect = { _, _ in },
        teamAllowed: @escaping @Sendable () -> Bool = { false },
        bulkChannels: BulkTerminalChannels? = nil,
        isBulkTransport: Bool = false
    ) {
        self.bulkChannels = bulkChannels
        self.isBulkTransport = isBulkTransport
        self.teamHandler = teamHandler
        self.teamOnConnect = teamOnConnect
        self.teamOnDisconnect = teamOnDisconnect
        self.teamAllowed = teamAllowed
        self.streamFactory = streamFactory
        self.pagedFactory = pagedFactory
        self.panesStateSubscribe = panesStateSubscribe
        self.panesStateV2Subscribe = panesStateV2Subscribe ?? panesStateSubscribe
        self.chromeTabMutator = chromeTabMutator
        self.chromeTabOnDisconnect = chromeTabOnDisconnect
        self.paneControlMutator = paneControlMutator
        self.worktreeManagementMutator = worktreeManagementMutator ?? { _ in
            .error(
                code: "unavailable",
                message: "worktree management is unavailable",
                forceAllowed: false,
                shortStatus: nil
            )
        }
        self.ownershipStore = ownershipStore
        self.ownershipBroadcaster = ownershipBroadcaster
        self.deviceIDProvider = deviceIDProvider
        self.worktreeManagementAllowed = worktreeManagementAllowed
        self.displayKindProvider = displayKindProvider
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
                // Fall back to a freshly generated device ID rather than
                // crashing if identity is somehow unresolved at
                // channel-open — SSH protocol makes this unreachable
                // (auth completes before any channel can open), but
                // `deviceIDProvider` is `RemoteDeviceID?` for testability
                // and this keeps a resolution gap from taking down the
                // channel entirely.
                let deviceID = deviceIDProvider() ?? RemoteDeviceID.generate()
                try context.pipeline.syncOperations.addHandler(
                    TerminalSessionHandler(
                        streamFactory: streamFactory,
                        ownershipStore: ownershipStore,
                        ownershipBroadcaster: ownershipBroadcaster,
                        deviceID: deviceID,
                        defaultKind: displayKindProvider(), bulkChannels: bulkChannels
                    ),
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
        if request.subsystem == GrafttyWebRTC.bulkSubsystem {
            dispatched = true
            if request.wantReply {
                if bulkChannels != nil { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
                else { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            }
            // The client closes after observing the reply. Closing here can
            // race the success message on a freshly authenticated transport.
            if bulkChannels == nil { context.close(promise: nil) }
            return
        }
        if request.subsystem.hasPrefix(GrafttyWebRTC.historySubsystemPrefix) {
            dispatched = true
            let token = String(request.subsystem.dropFirst(GrafttyWebRTC.historySubsystemPrefix.count))
            guard isBulkTransport, let bulkChannels, let deviceID = deviceIDProvider(),
                  bulkChannels.register(token: token, deviceID: deviceID, channel: context.channel) else {
                refuse(request, context: context)
                return
            }
            if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            return
        }
        if let spec = Self.framedSubsystems[request.subsystem] {
            dispatched = true
            guard let handler = spec.makeHandler(self) else {
                refuse(request, context: context)
                return
            }
            installSubsystem(
                handler: handler,
                maximumBufferSize: spec.maximumBufferSize,
                request: request,
                context: context
            )
            return
        }
        switch request.subsystem {
        case SSHChannelTypeNames.terminalPaged:
            guard let pagedFactory else {
                refuse(request, context: context)
                return
            }
            dispatched = true
            do {
                try context.pipeline.syncOperations.addHandler(TerminalSessionHandler(
                    streamFactory: streamFactory, pagedFactory: pagedFactory,
                    ownershipStore: ownershipStore, ownershipBroadcaster: ownershipBroadcaster,
                    deviceID: deviceIDProvider() ?? RemoteDeviceID.generate(), defaultKind: displayKindProvider(), bulkChannels: bulkChannels
                ), position: .after(self))
                if request.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
                context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            } catch {
                context.close(promise: nil)
            }

        default:
            // Unknown subsystem — refuse cleanly.
            refuse(request, context: context)
        }
    }

    /// A length-prefixed subsystem: its frame-decoder bound and a factory
    /// that returns `nil` to refuse the subsystem on this connection.
    private struct SubsystemSpec: Sendable {
        var maximumBufferSize: Int?
        let makeHandler: @Sendable (SubsystemDispatcher) -> (any ChannelHandler)?
    }

    private static let framedSubsystems: [String: SubsystemSpec] = [
        SSHChannelTypeNames.chromeTabs: SubsystemSpec(
            maximumBufferSize: ChromeTabRequest.maximumRequestBytes + 4
        ) { dispatcher in
            guard dispatcher.worktreeManagementAllowed(),
                  let deviceID = dispatcher.deviceIDProvider(),
                  let mutator = dispatcher.chromeTabMutator else { return nil }
            return ChromeTabChannelHandler(
                deviceID: deviceID, mutator: mutator, onDisconnect: dispatcher.chromeTabOnDisconnect
            )
        },
        SSHChannelTypeNames.team: SubsystemSpec(
            maximumBufferSize: TeamRPCSession.maximumEnvelopeBytes
        ) { dispatcher in
            guard dispatcher.teamAllowed(),
                  let deviceID = dispatcher.deviceIDProvider(),
                  let handler = dispatcher.teamHandler else { return nil }
            return TeamChannelHandler(
                deviceID: deviceID, handler: handler,
                onConnect: dispatcher.teamOnConnect, onDisconnect: dispatcher.teamOnDisconnect
            )
        },
        SSHChannelTypeNames.panesState: SubsystemSpec { dispatcher in
            PanesStateChannelHandler(subscribe: dispatcher.panesStateSubscribe)
        },
        SSHChannelTypeNames.panesStateV2: SubsystemSpec { dispatcher in
            PanesStateChannelHandler(subscribe: dispatcher.panesStateV2Subscribe)
        },
        SSHChannelTypeNames.paneControl: SubsystemSpec { dispatcher in
            PaneControlChannelHandler(mutator: dispatcher.paneControlMutator)
        },
        SSHChannelTypeNames.worktreeManagement: SubsystemSpec { dispatcher in
            guard dispatcher.worktreeManagementAllowed() else { return nil }
            return WorktreeManagementChannelHandler(mutator: dispatcher.worktreeManagementMutator)
        },
    ]

    /// Fails the request (if it wants a reply) and closes the channel.
    private func refuse(
        _ request: SSHChannelRequestEvent.SubsystemRequest,
        context: ChannelHandlerContext
    ) {
        if request.wantReply {
            context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
        }
        context.close(promise: nil)
    }

    /// Installs the shared framing stack (codec → decoder → prepender → `handler`)
    /// after `self` in the pipeline, acks or nacks the subsystem request, then
    /// removes `self`. Each `.after(self)` insert lands immediately after
    /// `self`, so inserting in reverse yields `[codec, decoder, prepender,
    /// handler]` from the channel inward.
    private func installSubsystem(
        handler: any NIOCore.ChannelHandler,
        maximumBufferSize: Int?,
        request: SSHChannelRequestEvent.SubsystemRequest,
        context: ChannelHandlerContext
    ) {
        do {
            let pipeline = context.pipeline.syncOperations
            try pipeline.addHandler(handler, position: .after(self))
            try pipeline.addHandler(LengthPrefixedFraming.makeFramePrepender(), position: .after(self))
            try pipeline.addHandler(
                LengthPrefixedFraming.makeFrameDecoder(maximumBufferSize: maximumBufferSize),
                position: .after(self)
            )
            // SSHChannelDataCodec bridges SSHChannelData ↔ ByteBuffer
            // so the downstream framing handlers operate on raw bytes.
            try pipeline.addHandler(SSHChannelDataCodec(), position: .after(self))
            if request.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }
            pipeline.removeHandler(context: context, promise: nil)
        } catch {
            refuse(request, context: context)
        }
    }
}
