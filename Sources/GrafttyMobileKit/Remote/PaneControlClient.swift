#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side actor that exposes typed RPC methods over the
/// `pane-control@graftty.dev` SSH subsystem. Wraps a
/// `PaneControlChannelDriver` and routes typed calls to the driver's
/// untyped `send(_:)` entry point.
///
/// Concurrency: Swift actors are **reentrant** at `await` boundaries.
/// While a `split(...)` call is suspended on `driver.send`, another
/// caller can enter the actor (e.g. via `close(target:)`) and reach the
/// driver again. Callers MUST therefore not issue concurrent RPCs
/// against the same `PaneControlClient`; the underlying driver will
/// throw `PaneControlChannelClient.ClientError.busy` if they do.
///
/// Public method surface unchanged from R4 — `RootView` consumers don't
/// need to change.
public actor PaneControlClient {

    public enum ClientError: Error, Equatable, Sendable {
        case notOpen
        case rpc(code: String, message: String)
    }

    private let driver: PaneControlChannelDriver

    public init(driver: PaneControlChannelDriver) {
        self.driver = driver
    }

    public func open() async throws {
        try await driver.open()
    }

    public func close() async {
        driver.close()
    }

    public func split(target: String, direction: PaneControlRequest.SplitDirection) async throws -> PaneControlResponse {
        try await driver.send(.split(target: target, direction: direction))
    }

    public func close(target: String) async throws -> PaneControlResponse {
        try await driver.send(.close(target: target))
    }

    public func swap(source: String, target: String) async throws -> PaneControlResponse {
        try await driver.send(.swap(source: source, target: target))
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
#endif
