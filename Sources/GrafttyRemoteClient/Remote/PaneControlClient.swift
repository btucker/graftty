import Foundation
import GrafttyProtocol

/// Client-side actor that exposes typed RPC methods over the
/// `pane-control@graftty.dev` SSH subsystem. Wraps a
/// `PaneControlChannelDriver` and routes typed calls to the driver's
/// untyped `send(_:)` entry point.
///
/// Concurrency: Swift actors are reentrant at `await` boundaries, so this
/// façade links requests into a FIFO before awaiting the channel driver.
/// Rapid UI actions therefore cannot collide with the driver's single-RPC
/// busy guard.
///
/// Public method surface unchanged from R4 — `RootView` consumers don't
/// need to change.
public actor PaneControlClient {

    public enum ClientError: Error, Equatable, Sendable {
        case notOpen
        case rpc(code: String, message: String)
    }

    private let driver: PaneControlChannelDriver
    private struct Operation {
        let id: UUID
        let task: Task<PaneControlResponse, Error>
    }
    private var operationTail: Operation?
    private var operations: [UUID: Task<PaneControlResponse, Error>] = [:]
    private var connectionGeneration: UInt64 = 0
    private var isOpen = false

    public init(driver: PaneControlChannelDriver) {
        self.driver = driver
    }

    public func open() async throws {
        let generation = connectionGeneration
        try await driver.open()
        guard generation == connectionGeneration else {
            driver.close()
            throw ClientError.notOpen
        }
        isOpen = true
    }

    public func close() async {
        connectionGeneration &+= 1
        isOpen = false
        for task in operations.values {
            task.cancel()
        }
        operations.removeAll()
        operationTail = nil
        driver.close()
    }

    public func split(target: String, direction: PaneControlRequest.SplitDirection) async throws -> PaneControlResponse {
        try await enqueue(.split(target: target, direction: direction))
    }

    public func close(target: String) async throws -> PaneControlResponse {
        try await enqueue(.close(target: target))
    }

    public func swap(source: String, target: String) async throws -> PaneControlResponse {
        try await enqueue(.swap(source: source, target: target))
    }

    public func equalize(target: String) async throws -> PaneControlResponse {
        try await enqueue(.equalize(target: target))
    }

    public func resize(
        target: String,
        direction: PaneControlRequest.SplitDirection,
        amount: UInt16,
        viewportExtent: UInt32? = nil
    ) async throws -> PaneControlResponse {
        try await enqueue(.resize(
            target: target,
            direction: direction,
            amount: amount,
            viewportExtent: viewportExtent
        ))
    }

    private func enqueue(
        _ request: PaneControlRequest
    ) async throws -> PaneControlResponse {
        guard isOpen else {
            throw ClientError.notOpen
        }
        let generation = connectionGeneration
        let previous = operationTail?.task
        let id = UUID()
        let driver = driver
        let task = Task<PaneControlResponse, Error> {
            if let previous {
                _ = try? await previous.value
            }
            try Task.checkCancellation()
            let response = try await driver.send(request)
            try Task.checkCancellation()
            return response
        }
        operations[id] = task
        operationTail = Operation(id: id, task: task)
        do {
            let response = try await task.value
            guard isOpen, generation == connectionGeneration else {
                throw ClientError.notOpen
            }
            operations[id] = nil
            if operationTail?.id == id {
                operationTail = nil
            }
            return response
        } catch {
            operations[id] = nil
            if operationTail?.id == id {
                operationTail = nil
            }
            throw error
        }
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
