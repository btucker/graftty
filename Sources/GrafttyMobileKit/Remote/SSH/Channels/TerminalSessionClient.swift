#if canImport(UIKit)
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH

/// Mobile-side `WebSocketClient` conformer that carries graftty terminal
/// I/O over an SSH session child channel.
///
/// Lifecycle:
///   1. `connect()` opens an SSH child channel of type `.session` via
///      the parent `NIOSSHHandler`, sends `env GRAFTTY_SESSION=<name>`,
///      `pty-req`, `shell`. Resolves when shell is accepted.
///   2. `send(.binary(data))` writes the bytes as `SSHChannelData` to
///      the channel.
///   3. `receive()` returns the next `.binary(Data)` from an internal
///      buffer (populated by the inbound handler).
///   4. `resize(cols:rows:)` sends an SSH `window-change` channel
///      request.
///   5. `close()` closes the SSH child channel; the server-side handler
///      sees `channelInactive` and tears down the stream.
public final class TerminalSessionClient: WebSocketClient, @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case notConnected
        case channelClosed
        case openFailed(any Error)
    }

    private let parentChannel: Channel
    private let parentHandler: NIOSSHHandler
    private let sessionName: String
    private let lock = NIOLock()
    private var childChannel: Channel?
    private var receiveBuffer: [Data] = []
    private var pendingReceivers: [CheckedContinuation<WebSocketFrame, Error>] = []
    private var didFailReceive: (any Error)?
    private var closed = false

    public init(parentChannel: Channel, parentHandler: NIOSSHHandler, sessionName: String) {
        self.parentChannel = parentChannel
        self.parentHandler = parentHandler
        self.sessionName = sessionName
    }

    /// Opens the SSH session child channel and completes env+pty+shell.
    public func connect() async throws {
        let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
        parentHandler.createChannel(promise, channelType: .session) { [weak self] child, _ in
            guard let self else {
                return child.eventLoop.makeFailedFuture(ClientError.notConnected)
            }
            return child.pipeline.addHandler(InboundRelay(owner: self))
        }
        let child: Channel
        do {
            child = try await promise.futureResult.get()
        } catch {
            throw ClientError.openFailed(error)
        }
        try await Self.sendEnv(channel: child, name: "GRAFTTY_SESSION", value: sessionName)
        try await Self.sendPty(channel: child, term: "xterm-256color", cols: 80, rows: 24)
        try await Self.sendShell(channel: child)

        lock.withLock {
            childChannel = child
        }

        // Watch for child-channel close so receivers waiting in
        // `receive()` see channelClosed instead of hanging.
        child.closeFuture.whenComplete { [weak self] _ in
            self?.handleChildClose()
        }
    }

    public func send(_ frame: WebSocketFrame) async throws {
        let child = lock.withLock { childChannel }
        guard let child else { throw ClientError.notConnected }
        let bytes: Data
        switch frame {
        case .binary(let data): bytes = data
        case .text(let s): bytes = Data(s.utf8)
        }
        let buffer = child.allocator.buffer(bytes: bytes)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        try await child.writeAndFlush(data).get()
    }

    public func receive() async throws -> WebSocketFrame {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebSocketFrame, Error>) in
            lock.withLock {
                if let error = didFailReceive {
                    cont.resume(throwing: error)
                    return
                }
                if !receiveBuffer.isEmpty {
                    let next = receiveBuffer.removeFirst()
                    cont.resume(returning: .binary(next))
                    return
                }
                if closed {
                    cont.resume(throwing: ClientError.channelClosed)
                    return
                }
                pendingReceivers.append(cont)
            }
        }
    }

    public func close() {
        let child = lock.withLock { () -> Channel? in
            closed = true
            return childChannel
        }
        child?.close(promise: nil)
    }

    public func resize(cols: Int, rows: Int) async {
        let child = lock.withLock { childChannel }
        guard let child else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try? await child.triggerUserOutboundEvent(event).get()
    }

    // MARK: - Inbound bytes from the SSH channel

    fileprivate func deliverInbound(_ data: Data) {
        lock.withLock {
            if let next = pendingReceivers.first {
                pendingReceivers.removeFirst()
                next.resume(returning: .binary(data))
            } else {
                receiveBuffer.append(data)
            }
        }
    }

    fileprivate func handleChildClose() {
        let toResume: [CheckedContinuation<WebSocketFrame, Error>] = lock.withLock {
            let pending = pendingReceivers
            pendingReceivers.removeAll()
            closed = true
            didFailReceive = ClientError.channelClosed
            return pending
        }
        for cont in toResume {
            cont.resume(throwing: ClientError.channelClosed)
        }
    }

    // MARK: - Channel-request senders

    private static func sendEnv(channel: Channel, name: String, value: String) async throws {
        let event = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: true,
            name: name,
            value: value
        )
        try await channel.triggerUserOutboundEvent(event).get()
    }

    private static func sendPty(channel: Channel, term: String, cols: Int, rows: Int) async throws {
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await channel.triggerUserOutboundEvent(event).get()
    }

    private static func sendShell(channel: Channel) async throws {
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await channel.triggerUserOutboundEvent(event).get()
    }
}

/// Inbound relay installed on the SSH child channel. Forwards inbound
/// `SSHChannelData` to the owning `TerminalSessionClient`.
///
/// `@unchecked Sendable`: `owner` is a `weak var` to `TerminalSessionClient`
/// which is itself `@unchecked Sendable`. All mutations go through the NIO
/// event-loop thread that drives this handler, so cross-actor access is safe.
private final class InboundRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    weak var owner: TerminalSessionClient?

    init(owner: TerminalSessionClient) {
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(buf) = channelData.data else { return }
        var view = buf
        guard let bytes = view.readBytes(length: view.readableBytes) else { return }
        owner?.deliverInbound(Data(bytes))
    }
}
#endif
