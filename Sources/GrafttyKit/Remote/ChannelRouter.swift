import Foundation
import GrafttyProtocol

public protocol ChannelTransport: Sendable {
    func send(_ data: Data) async throws
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async
}

public protocol ChannelHandler: Sendable {
    var channelType: String { get }
    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async
    func onPayload(_ data: Data) async
    func onClose() async
    func onError(_ code: String, message: String) async
}

public struct ChannelOutbox: Sendable {
    private let _send: @Sendable (ChannelFrame) async throws -> Void
    public init(send: @escaping @Sendable (ChannelFrame) async throws -> Void) {
        self._send = send
    }
    public func send(_ frame: ChannelFrame) async throws {
        try await _send(frame)
    }
}

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

    public func register(
        type: String,
        factory: @escaping @Sendable () -> ChannelHandler
    ) {
        handlerFactoriesByType[type] = factory
    }

    @discardableResult
    public func open(
        type: String,
        handler: ChannelHandler
    ) async throws -> ChannelID {
        let id = ChannelID(nextOutboundID)
        nextOutboundID &+= 1
        handlersByID[id] = handler
        let frame: ChannelFrame = .open(ChannelOpen(id: id, type: type))
        do {
            try await sendFrame(frame)
        } catch {
            // Roll back the registration: the remote never received the
            // open, so no `close` frame will ever arrive to clean it up.
            handlersByID.removeValue(forKey: id)
            throw error
        }
        let outbox = ChannelOutbox { [weak self] frame in
            try await self?.sendFrame(frame)
        }
        await handler.onOpen(id, outbox: outbox)
        return id
    }

    public func start() async {
        await transport.onReceive { [weak self] data in
            await self?.dispatch(data)
        }
    }

    public func close(_ id: ChannelID) async throws {
        guard handlersByID[id] != nil else { return }
        try await sendFrame(.close(ChannelClose(id: id)))
        // Send succeeded — remove and notify atomically from the remote's
        // perspective.
        let handler = handlersByID.removeValue(forKey: id)
        await handler?.onClose()
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
            return
        }
        switch frame {
        case .open(let m):
            guard m.id != .reserved else {
                try? await sendFrame(.error(ChannelError(
                    id: m.id,
                    code: "channel-id-reserved",
                    message: "channel id 0 is reserved for the channel layer"
                )))
                return
            }
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
