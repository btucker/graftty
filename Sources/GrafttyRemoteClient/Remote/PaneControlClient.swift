import Foundation
import GrafttyProtocol

/// Typed RPC methods over the `pane-control@graftty.dev` SSH subsystem.
/// Wraps a `PaneControlChannelDriver` in a `SerialRPCClient`, so rapid UI
/// actions queue in order instead of colliding with the driver's
/// single-RPC busy guard.
public final class PaneControlClient: Sendable {

    public enum ClientError: Error, Equatable, Sendable {
        case notOpen
        case rpc(code: String, message: String)
    }

    private let rpc: SerialRPCClient<PaneControlRequest, PaneControlResponse>

    public init(driver: PaneControlChannelDriver) {
        rpc = SerialRPCClient(
            policy: .init(
                closedError: ClientError.notOpen,
                queueLimit: nil,
                closesOnCallerCancellation: false
            ),
            open: { try await driver.open() },
            send: { try await driver.send($0) },
            close: { driver.close() }
        )
    }

    public func open() async throws {
        try await rpc.open()
    }

    public func close() async {
        await rpc.close()
    }

    public func split(target: String, direction: PaneControlRequest.SplitDirection) async throws -> PaneControlResponse {
        try await rpc.send(.split(target: target, direction: direction))
    }

    public func close(target: String) async throws -> PaneControlResponse {
        try await rpc.send(.close(target: target))
    }

    public func swap(source: String, target: String) async throws -> PaneControlResponse {
        try await rpc.send(.swap(source: source, target: target))
    }

    public func equalize(target: String) async throws -> PaneControlResponse {
        try await rpc.send(.equalize(target: target))
    }

    public func resize(
        target: String,
        direction: PaneControlRequest.SplitDirection,
        amount: UInt16,
        viewportExtent: UInt32? = nil
    ) async throws -> PaneControlResponse {
        try await rpc.send(.resize(
            target: target,
            direction: direction,
            amount: amount,
            viewportExtent: viewportExtent
        ))
    }
}

/// Protocol exposed for test substitution. `PaneControlChannelClient`
/// conforms; tests substitute a fake.
public protocol PaneControlChannelDriver: Sendable {
    func open() async throws
    func close()
    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse
}

extension PaneControlChannelClient: PaneControlChannelDriver {}
