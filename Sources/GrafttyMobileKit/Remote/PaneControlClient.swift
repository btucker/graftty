#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side actor that exposes typed RPC methods over the
/// `pane-control@graftty.dev` SSH subsystem. Wraps a
/// `PaneControlChannelDriver` and serialises concurrent caller
/// invocations through the actor's executor.
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
