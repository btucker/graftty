import Foundation
import GrafttyProtocol

public protocol ChromeTabChannelDriver: Sendable {
    func open() async throws
    func close()
    func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse
}

extension ChromeTabChannelClient: ChromeTabChannelDriver {}

/// Serializes input behind frame pulls with a fixed queue bound.
public final class ChromeTabClient: Sendable {
    public enum Failure: Error { case closed, queueFull }
    private let rpc: SerialRPCClient<ChromeTabRequest, ChromeTabResponse>

    public init(driver: any ChromeTabChannelDriver) {
        rpc = SerialRPCClient(
            policy: .init(
                closedError: Failure.closed,
                queueLimit: (count: 8, error: Failure.queueFull),
                // The wire has no request IDs. Close before accepting another reply.
                closesOnCallerCancellation: true
            ),
            open: { try await driver.open() },
            send: { try await driver.send($0) },
            close: { driver.close() }
        )
    }

    public var pendingRequestCount: Int {
        get async { await rpc.pendingCount }
    }

    public func open() async throws { try await rpc.open() }
    public func cancel() { rpc.cancel() }
    public func close() async { await rpc.close() }
    public func send(_ request: ChromeTabRequest) async throws -> ChromeTabResponse {
        try await rpc.send(request)
    }
}
