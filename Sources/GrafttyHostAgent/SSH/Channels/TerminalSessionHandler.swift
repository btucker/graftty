import Foundation
import GrafttyKit
import NIOCore
import NIOSSH

/// Server-side SSH channel handler for graftty's terminal session
/// channel. Installs on an inbound SSH session child channel and:
///
///   1. Collects `env GRAFTTY_SESSION=<name>` and `pty-req` channel
///      requests as they arrive.
///   2. On `shell`, calls the injected `streamFactory(name)` to obtain
///      a `TerminalByteStream` (which in production wraps a
///      `Process` spawning `zmx attach <name>`).
///   3. Bridges bytes both ways: inbound `SSHChannelData` -> `stream.send`;
///      `stream.inboundBytes` -> outbound `SSHChannelData`.
///   4. Forwards `window-change` channel requests to `stream.resize`.
///   5. On channel close, calls `stream.close()` — which terminates the
///      `zmx attach` Process. The user's shell survives because it
///      runs in the zmx daemon, attached/detached transparently.
///   6. If `streamFactory` throws, sends `exit-status: 1` and closes
///      the channel.
/// Concurrency: `@unchecked Sendable` because all mutable state
/// (`envSessionName`, `ptyAccepted`, `stream`, `inboundForwardingTask`)
/// is accessed exclusively on the channel's event loop. NIO guarantees
/// `channelRead`, `userInboundEventTriggered`, and `channelInactive` all
/// run on that loop; `loop.execute` callbacks in `attach` also run there.
public final class TerminalSessionHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    private let streamFactory: @Sendable (String) async throws -> TerminalByteStream
    private var envSessionName: String?
    private var ptyAccepted = false
    private var stream: TerminalByteStream?
    private var inboundForwardingTask: Task<Void, Never>?

    public init(streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream) {
        self.streamFactory = streamFactory
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard stream != nil else {
            // Bytes arrived before `shell` completed attach; drop them.
            // Real clients never do this — SSH state machine prevents
            // shell-before-data — but be defensive.
            return
        }
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        let snapshot = stream
        Task { [snapshot] in
            try? await snapshot?.send(Data(bytes))
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let envEvent as SSHChannelRequestEvent.EnvironmentRequest:
            if envEvent.name == "GRAFTTY_SESSION" {
                envSessionName = envEvent.value
            }
            // Acknowledge the env request if a reply was requested.
            // (Other env names are accepted silently — no-op.)
            if envEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let ptyEvent as SSHChannelRequestEvent.PseudoTerminalRequest:
            // Accept any pty-req. We don't capture initial cols/rows
            // here because the stream isn't attached yet; the client
            // re-sends window-change after shell completes if needed.
            ptyAccepted = true
            if ptyEvent.wantReply {
                context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            }

        case let shellEvent as SSHChannelRequestEvent.ShellRequest:
            guard let name = envSessionName else {
                // No GRAFTTY_SESSION env — we have nothing to attach to.
                if shellEvent.wantReply {
                    context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                }
                context.close(promise: nil)
                return
            }
            attach(context: context, sessionName: name, wantReply: shellEvent.wantReply)

        case let winEvent as SSHChannelRequestEvent.WindowChangeRequest:
            guard let snapshot = stream else { return }
            // terminalCharacterWidth and terminalRowHeight return Int directly.
            let cols = winEvent.terminalCharacterWidth
            let rows = winEvent.terminalRowHeight
            Task { [snapshot] in
                await snapshot.resize(cols: cols, rows: rows)
            }

        default:
            // Other channel-request events (exec, signal, exit-*) are
            // not used by graftty's iPad client; ignore.
            break
        }
    }

    public func channelInactive(context: ChannelHandlerContext) {
        inboundForwardingTask?.cancel()
        let snapshot = stream
        stream = nil
        Task { [snapshot] in
            await snapshot?.close()
        }
        context.fireChannelInactive()
    }

    private func attach(context: ChannelHandlerContext, sessionName: String, wantReply: Bool) {
        let factory = streamFactory
        let channel = context.channel
        let loop = context.eventLoop
        // Use the channel's pipeline for outbound events — Channel is
        // Sendable, ChannelHandlerContext is not.
        let pipeline = context.pipeline

        Task { [weak self] in
            do {
                let stream = try await factory(sessionName)
                loop.execute { [weak self] in
                    guard let self else { return }
                    self.stream = stream
                    if wantReply {
                        pipeline.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
                    }
                    self.startInboundForwarding(stream: stream, channel: channel, loop: loop)
                }
            } catch {
                loop.execute {
                    if wantReply {
                        pipeline.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
                    }
                    let exit = SSHChannelRequestEvent.ExitStatus(exitStatus: 1)
                    pipeline.triggerUserOutboundEvent(exit, promise: nil)
                    channel.close(promise: nil)
                }
            }
        }
    }

    private func startInboundForwarding(stream: TerminalByteStream, channel: Channel, loop: EventLoop) {
        let task = Task {
            for await chunk in stream.inboundBytes {
                let buffer = channel.allocator.buffer(bytes: chunk)
                let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                loop.execute {
                    channel.writeAndFlush(data, promise: nil)
                }
            }
        }
        inboundForwardingTask = task
    }
}
