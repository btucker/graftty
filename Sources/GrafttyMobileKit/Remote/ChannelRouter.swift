#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Abstract send/receive surface for the `ChannelRouter`. Production wires
/// this to an `RTCDataChannel`; tests inject an in-memory transport.
public protocol ChannelTransport: Sendable {
    func send(_ data: Data) async throws
    /// Hand the next inbound `Data` blob (one DataChannel message) to the
    /// router. The router decodes and dispatches.
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async
}

/// Receives frames addressed to a single channel and writes outbound frames
/// via the supplied `ChannelOutbox`. Concrete handlers (e.g. for
/// `terminal`, `panes_state`, `pane_control`) implement this.
public protocol ChannelHandler: Sendable {
    var channelType: String { get }
    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async
    func onPayload(_ data: Data) async
    func onClose() async
    func onError(_ code: String, message: String) async
}

/// Limited-surface object handed to a `ChannelHandler` so it can write
/// outbound frames without holding a reference to the whole router.
public struct ChannelOutbox: Sendable {
    private let _send: @Sendable (ChannelFrame) async throws -> Void
    public init(send: @escaping @Sendable (ChannelFrame) async throws -> Void) {
        self._send = send
    }
    public func send(_ frame: ChannelFrame) async throws {
        try await _send(frame)
    }
}

/// Multiplexes N logical channels over a single `ChannelTransport`.
/// Owns the inbound dispatch loop, the per-`ChannelID` handler map, and
/// the allocator for outbound `ChannelID`s.
public actor ChannelRouter {

    public enum RouterError: Error, Equatable, Sendable {
        case noHandlerForType(String)
        case unknownChannelID(ChannelID)
        case encodeFailed(String)
        case decodeFailed(String)
    }

    private let transport: ChannelTransport
    private var handlersByID: [ChannelID: ChannelHandler] = [:]
    private var handlerFactoriesByType: [String: @Sendable () -> ChannelHandler] = [:]
    private var nextOutboundID: UInt32 = 1

    public init(transport: ChannelTransport) {
        self.transport = transport
    }

    /// Register a factory that produces a fresh handler for inbound `open`
    /// frames of `type`. The router calls the factory each time an inbound
    /// `open` arrives; the handler's `onOpen` is then awaited before the
    /// next frame for the same channel-id is dispatched.
    public func register(
        type: String,
        factory: @escaping @Sendable () -> ChannelHandler
    ) {
        handlerFactoriesByType[type] = factory
    }

    /// Open an outbound channel of `type`. Returns the allocated `ChannelID`
    /// and the handler the caller registered via this opening.
    @discardableResult
    public func open(
        type: String,
        handler: ChannelHandler
    ) async throws -> ChannelID {
        let id = ChannelID(nextOutboundID)
        nextOutboundID &+= 1
        handlersByID[id] = handler
        let frame: ChannelFrame = .open(ChannelOpen(id: id, type: type))
        try await sendFrame(frame)
        let outbox = ChannelOutbox { [weak self] frame in
            try await self?.sendFrame(frame)
        }
        await handler.onOpen(id, outbox: outbox)
        return id
    }

    /// Begin the inbound dispatch loop. Call once after construction.
    public func start() async {
        await transport.onReceive { [weak self] data in
            await self?.dispatch(data)
        }
    }

    public func close(_ id: ChannelID) async throws {
        guard let handler = handlersByID.removeValue(forKey: id) else { return }
        await handler.onClose()
        try await sendFrame(.close(ChannelClose(id: id)))
    }

    private func sendFrame(_ frame: ChannelFrame) async throws {
        let data: Data
        do {
            data = try ChannelFrameCoder.encode(frame)
        } catch {
            throw RouterError.encodeFailed(String(describing: error))
        }
        try await transport.send(data)
    }

    private func dispatch(_ data: Data) async {
        let frame: ChannelFrame
        do {
            frame = try ChannelFrameCoder.decode(data)
        } catch {
            // Decoder failure on an unknown peer's frame is logged-and-dropped
            // rather than fatal — a future peer with a newer wire format
            // shouldn't crash this side.
            return
        }
        switch frame {
        case .open(let m):
            guard let factory = handlerFactoriesByType[m.type] else {
                try? await sendFrame(.error(ChannelError(
                    id: m.id,
                    code: "channel-type-unknown",
                    message: "no handler factory for type '\(m.type)'"
                )))
                return
            }
            let handler = factory()
            handlersByID[m.id] = handler
            let outbox = ChannelOutbox { [weak self] frame in
                try await self?.sendFrame(frame)
            }
            await handler.onOpen(m.id, outbox: outbox)
        case .close(let m):
            guard let handler = handlersByID.removeValue(forKey: m.id) else { return }
            await handler.onClose()
        case .payload(let m, let bytes):
            guard let handler = handlersByID[m.id] else { return }
            await handler.onPayload(bytes)
        case .error(let m):
            guard let handler = handlersByID.removeValue(forKey: m.id) else { return }
            await handler.onError(m.code, message: m.message)
        }
    }
}
#endif
